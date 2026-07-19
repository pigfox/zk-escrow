package app

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/pigfox/zk-escrow/agent/internal/ai"
	"github.com/pigfox/zk-escrow/agent/internal/arbiter"
	"github.com/pigfox/zk-escrow/agent/internal/config"
)

// fakeNode is a nodeClient that answers nothing and records its shutdown.
type fakeNode struct{ closed bool }

func (f *fakeNode) BlockNumber(context.Context) (uint64, error) { return 0, nil }

func (f *fakeNode) FilterLogs(context.Context, ethereum.FilterQuery) ([]types.Log, error) {
	return nil, nil
}

func (f *fakeNode) CallContract(
	context.Context, ethereum.CallMsg, *big.Int,
) ([]byte, error) {
	return nil, nil
}

func (f *fakeNode) Close() { f.closed = true }

// deadTicker never fires, so Run's only exit is context cancellation.
type deadTicker struct{ stopped bool }

func (d *deadTicker) C() <-chan time.Time { return make(chan time.Time) }
func (d *deadTicker) Stop()               { d.stopped = true }

// setValidEnv installs a complete, valid configuration.
func setValidEnv(t *testing.T) {
	t.Helper()
	t.Setenv(config.EnvPrivateKey, "0xkey")
	t.Setenv(config.EnvAnthropicAPIKey, "sk-ant-test")
	t.Setenv(config.EnvRPCURL, "http://localhost:8545")
	t.Setenv(config.EnvEscrowAddress, "0x1234567890123456789012345678901234567890")
}

// stubSeams replaces the production seams for the duration of the test.
func stubSeams(t *testing.T, d dialer, abiJSON string, ticker arbiter.Ticker) {
	t.Helper()
	origDial, origABI, origTicker := dial, escrowABI, newTicker
	t.Cleanup(func() { dial, escrowABI, newTicker = origDial, origABI, origTicker })
	dial = d
	escrowABI = abiJSON
	newTicker = func() arbiter.Ticker { return ticker }
}

func TestRunConfigFailure(t *testing.T) {
	t.Setenv(config.EnvPrivateKey, "")
	t.Setenv(config.EnvAnthropicAPIKey, "")

	var out bytes.Buffer
	if code := Run(t.Context(), &out); code != config.ExitConfigError {
		t.Fatalf("Run() = %d, want %d", code, config.ExitConfigError)
	}
	if !strings.Contains(out.String(), config.EnvPrivateKey) {
		t.Errorf("log should name the missing variable:\n%s", out.String())
	}
}

func TestRunDialFailure(t *testing.T) {
	setValidEnv(t)
	dialErr := errors.New("no route to host")
	stubSeams(t, func(context.Context, string) (nodeClient, error) {
		return nil, dialErr
	}, config.EscrowABIJSON, &deadTicker{})

	var out bytes.Buffer
	if code := Run(t.Context(), &out); code != config.ExitDialError {
		t.Fatalf("Run() = %d, want %d", code, config.ExitDialError)
	}
	if !strings.Contains(out.String(), "no route to host") {
		t.Errorf("log should carry the dial error:\n%s", out.String())
	}
}

func TestRunChainBindingFailure(t *testing.T) {
	setValidEnv(t)
	node := &fakeNode{}
	stubSeams(t, func(context.Context, string) (nodeClient, error) {
		return node, nil
	}, `{not valid abi json`, &deadTicker{})

	var out bytes.Buffer
	if code := Run(t.Context(), &out); code != config.ExitChainError {
		t.Fatalf("Run() = %d, want %d", code, config.ExitChainError)
	}
	if !node.closed {
		t.Error("the RPC connection must be closed even on a binding failure")
	}
}

func TestRunCleanShutdown(t *testing.T) {
	setValidEnv(t)
	node := &fakeNode{}
	ticker := &deadTicker{}
	stubSeams(t, func(context.Context, string) (nodeClient, error) {
		return node, nil
	}, config.EscrowABIJSON, ticker)

	ctx, cancel := context.WithCancel(t.Context())
	cancel() // Run must observe the cancellation on its first select.

	var out bytes.Buffer
	if code := Run(ctx, &out); code != config.ExitOK {
		t.Fatalf("Run() = %d, want %d", code, config.ExitOK)
	}
	if !node.closed {
		t.Error("the RPC connection must be closed on shutdown")
	}
	if !ticker.stopped {
		t.Error("the ticker must be stopped on shutdown")
	}

	logged := out.String()
	if !strings.Contains(logged, config.AnthropicModel) {
		t.Errorf("startup banner should name the model:\n%s", logged)
	}
	if !strings.Contains(logged, "84532") {
		t.Errorf("startup banner should name the Base Sepolia chain id:\n%s", logged)
	}
	if strings.Contains(logged, "0xkey") || strings.Contains(logged, "sk-ant-test") {
		t.Fatalf("startup banner leaked a secret:\n%s", logged)
	}
}

// TestDefaultDial covers the production dialer. Base Sepolia is reached over
// HTTP, so a valid URL succeeds without any network traffic.
func TestDefaultDial(t *testing.T) {
	t.Run("http endpoint", func(t *testing.T) {
		client, err := defaultDial(t.Context(), "http://localhost:8545")
		if err != nil {
			t.Fatalf("defaultDial() unexpected error: %v", err)
		}
		client.Close()
	})

	t.Run("unsupported scheme", func(t *testing.T) {
		if _, err := defaultDial(t.Context(), "gopher://localhost"); err == nil {
			t.Fatal("defaultDial() expected an error for an unsupported scheme")
		}
	})
}

// TestDefaultNewTicker covers the production clock factory.
func TestDefaultNewTicker(t *testing.T) {
	ticker := newTicker()
	if ticker == nil {
		t.Fatal("newTicker() returned nil")
	}
	ticker.Stop()
}

// TestNewModelClientSelectsTheProvider covers the wiring fork: the selected
// provider must produce that vendor's client, and the banner must name the
// model actually in use rather than a hardcoded one.
//
// config.Load has already rejected anything outside these two values, so the
// only cases here are the two valid ones plus the defensive fallback.
func TestNewModelClientSelectsTheProvider(t *testing.T) {
	tests := []struct {
		name      string
		cfg       config.Config
		wantModel string
		wantType  string
	}{
		{
			name: "anthropic",
			cfg: config.Config{
				AIProvider:      config.ProviderAnthropic,
				AnthropicAPIKey: "sk-ant",
			},
			wantModel: config.AnthropicModel,
			wantType:  "*ai.HTTPClient",
		},
		{
			name: "openai",
			cfg: config.Config{
				AIProvider:   config.ProviderOpenAI,
				OpenAIAPIKey: "sk-openai",
			},
			wantModel: config.OpenAIModel,
			wantType:  "*ai.OpenAIClient",
		},
		{
			name: "an unset provider falls back to the documented default",
			cfg: config.Config{
				AnthropicAPIKey: "sk-ant",
			},
			wantModel: config.AnthropicModel,
			wantType:  "*ai.HTTPClient",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, model := newModelClient(tt.cfg)

			if model != tt.wantModel {
				t.Errorf("model = %q, want %q", model, tt.wantModel)
			}
			if got := fmt.Sprintf("%T", client); got != tt.wantType {
				t.Errorf("client type = %s, want %s", got, tt.wantType)
			}
		})
	}
}

// TestNewModelClientCarriesTheRightKey guards against the two providers being
// wired to each other's credentials.
func TestNewModelClientCarriesTheRightKey(t *testing.T) {
	anthropic, _ := newModelClient(config.Config{
		AIProvider:      config.ProviderAnthropic,
		AnthropicAPIKey: "sk-ant",
		OpenAIAPIKey:    "sk-openai",
	})
	typed, ok := anthropic.(*ai.HTTPClient)
	if !ok {
		t.Fatalf("expected *ai.HTTPClient, got %T", anthropic)
	}
	if typed.APIKey != "sk-ant" {
		t.Error("anthropic client did not receive the anthropic key")
	}

	openAI, _ := newModelClient(config.Config{
		AIProvider:      config.ProviderOpenAI,
		AnthropicAPIKey: "sk-ant",
		OpenAIAPIKey:    "sk-openai",
	})
	typedOpenAI, ok := openAI.(*ai.OpenAIClient)
	if !ok {
		t.Fatalf("expected *ai.OpenAIClient, got %T", openAI)
	}
	if typedOpenAI.APIKey != "sk-openai" {
		t.Error("openai client did not receive the openai key")
	}
}
