package config_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/pigfox/zk-escrow/agent/internal/config"
)

const (
	testKey     = "0xabc123"
	testAPIKey  = "sk-ant-test"
	testOpenAI  = "sk-openai-test"
	testAddress = "0x1234567890123456789012345678901234567890"
)

// setEnv installs the given variables for the duration of the test, clearing
// any the caller did not name.
func setEnv(t *testing.T, vars map[string]string) {
	t.Helper()
	for _, name := range []string{
		config.EnvPrivateKey,
		config.EnvAnthropicAPIKey,
		config.EnvOpenAIAPIKey,
		config.EnvAIProvider,
		config.EnvRPCURL,
		config.EnvEscrowAddress,
		config.EnvStartBlockLookback,
	} {
		t.Setenv(name, vars[name])
	}
}

func TestLoad(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		wantErr error
		check   func(t *testing.T, cfg config.Config)
	}{
		{
			name: "defaults applied when only required vars are set",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
			},
			check: func(t *testing.T, cfg config.Config) {
				t.Helper()
				if cfg.RPCURL != config.DefaultRPCURL {
					t.Errorf("RPCURL = %q, want %q", cfg.RPCURL, config.DefaultRPCURL)
				}
				if cfg.ChainID != config.ChainID {
					t.Errorf("ChainID = %d, want %d", cfg.ChainID, config.ChainID)
				}
				if cfg.PrivateKey != testKey {
					t.Errorf("PrivateKey = %q, want %q", cfg.PrivateKey, testKey)
				}
				if cfg.AnthropicAPIKey != testAPIKey {
					t.Errorf("AnthropicAPIKey = %q, want %q", cfg.AnthropicAPIKey, testAPIKey)
				}
			},
		},
		{
			name: "overrides applied",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvRPCURL:          "http://localhost:8545",
				config.EnvEscrowAddress:   testAddress,
			},
			check: func(t *testing.T, cfg config.Config) {
				t.Helper()
				if cfg.RPCURL != "http://localhost:8545" {
					t.Errorf("RPCURL = %q", cfg.RPCURL)
				}
				if cfg.EscrowAddress.Hex() != "0x1234567890123456789012345678901234567890" {
					t.Errorf("EscrowAddress = %s", cfg.EscrowAddress.Hex())
				}
			},
		},
		{
			name:    "missing private key",
			env:     map[string]string{config.EnvAnthropicAPIKey: testAPIKey},
			wantErr: config.ErrMissingPrivateKey,
		},
		{
			name:    "missing anthropic api key",
			env:     map[string]string{config.EnvPrivateKey: testKey},
			wantErr: config.ErrMissingAnthropicAPIKey,
		},
		{
			name: "invalid escrow address",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvEscrowAddress:   "not-an-address",
			},
			wantErr: config.ErrInvalidEscrowAddress,
		},
		{
			name: "rpc url with unsupported scheme",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvRPCURL:          "ws://localhost:8546",
			},
			wantErr: config.ErrInvalidRPCURL,
		},
		{
			name: "rpc url without host",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvRPCURL:          "https://",
			},
			wantErr: config.ErrInvalidRPCURL,
		},
		{
			name: "rpc url that fails to parse",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvRPCURL:          "http://[::1]:namedport",
			},
			wantErr: config.ErrInvalidRPCURL,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setEnv(t, tt.env)

			cfg, err := config.Load()
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("Load() error = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() unexpected error: %v", err)
			}
			tt.check(t, cfg)
		})
	}
}

// TestChainIDIsBaseSepolia guards the one constant that must never drift.
func TestChainIDIsBaseSepolia(t *testing.T) {
	if config.ChainID != 84532 {
		t.Fatalf("ChainID = %d, want 84532 (Base Sepolia)", config.ChainID)
	}
	if config.ChainIDDecimal != "84532" {
		t.Fatalf("ChainIDDecimal = %q, want \"84532\"", config.ChainIDDecimal)
	}
}

// TestRulingEnumMatchesSolidity guards the enum ordering the contract relies on.
func TestRulingEnumMatchesSolidity(t *testing.T) {
	if config.RulingBuyerWins != 0 {
		t.Errorf("RulingBuyerWins = %d, want 0", config.RulingBuyerWins)
	}
	if config.RulingSellerWins != 1 {
		t.Errorf("RulingSellerWins = %d, want 1", config.RulingSellerWins)
	}
	if config.StateDisputed != 5 {
		t.Errorf("StateDisputed = %d, want 5", config.StateDisputed)
	}
}

// TestLoadProviderSelection covers which model key is required for which
// AI_PROVIDER. The point is that an operator running against OpenAI is never
// asked for an Anthropic key, and vice versa.
func TestLoadProviderSelection(t *testing.T) {
	tests := []struct {
		name          string
		env           map[string]string
		wantErr       error
		wantProvider  string
		wantAnthropic string
		wantOpenAI    string
	}{
		{
			name: "unset provider defaults to anthropic",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvEscrowAddress:   testAddress,
			},
			wantProvider:  config.ProviderAnthropic,
			wantAnthropic: testAPIKey,
		},
		{
			name: "explicit anthropic",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvAIProvider:      config.ProviderAnthropic,
				config.EnvEscrowAddress:   testAddress,
			},
			wantProvider:  config.ProviderAnthropic,
			wantAnthropic: testAPIKey,
		},
		{
			name: "openai needs only the openai key",
			env: map[string]string{
				config.EnvPrivateKey:    testKey,
				config.EnvOpenAIAPIKey:  testOpenAI,
				config.EnvAIProvider:    config.ProviderOpenAI,
				config.EnvEscrowAddress: testAddress,
			},
			wantProvider: config.ProviderOpenAI,
			wantOpenAI:   testOpenAI,
		},
		{
			name: "provider value is case and space insensitive",
			env: map[string]string{
				config.EnvPrivateKey:    testKey,
				config.EnvOpenAIAPIKey:  testOpenAI,
				config.EnvAIProvider:    "  OpenAI  ",
				config.EnvEscrowAddress: testAddress,
			},
			wantProvider: config.ProviderOpenAI,
			wantOpenAI:   testOpenAI,
		},
		{
			name: "anthropic selected but its key is empty",
			env: map[string]string{
				config.EnvPrivateKey:    testKey,
				config.EnvOpenAIAPIKey:  testOpenAI,
				config.EnvAIProvider:    config.ProviderAnthropic,
				config.EnvEscrowAddress: testAddress,
			},
			wantErr: config.ErrMissingAnthropicAPIKey,
		},
		{
			name: "openai selected but its key is empty",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvAIProvider:      config.ProviderOpenAI,
				config.EnvEscrowAddress:   testAddress,
			},
			wantErr: config.ErrMissingOpenAIAPIKey,
		},
		{
			name: "unknown provider is rejected",
			env: map[string]string{
				config.EnvPrivateKey:      testKey,
				config.EnvAnthropicAPIKey: testAPIKey,
				config.EnvOpenAIAPIKey:    testOpenAI,
				config.EnvAIProvider:      "gemini",
				config.EnvEscrowAddress:   testAddress,
			},
			wantErr: config.ErrUnknownAIProvider,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setEnv(t, tt.env)

			cfg, err := config.Load()
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("Load() error = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() unexpected error: %v", err)
			}

			if cfg.AIProvider != tt.wantProvider {
				t.Errorf("AIProvider = %q, want %q", cfg.AIProvider, tt.wantProvider)
			}
			if cfg.AnthropicAPIKey != tt.wantAnthropic {
				t.Errorf("AnthropicAPIKey was not the expected value")
			}
			if cfg.OpenAIAPIKey != tt.wantOpenAI {
				t.Errorf("OpenAIAPIKey was not the expected value")
			}
		})
	}
}

// TestUnknownProviderErrorNamesTheOffendingValue keeps the startup failure
// actionable: the operator needs to see what they typed.
func TestUnknownProviderErrorNamesTheOffendingValue(t *testing.T) {
	setEnv(t, map[string]string{
		config.EnvPrivateKey:      testKey,
		config.EnvAnthropicAPIKey: testAPIKey,
		config.EnvAIProvider:      "clyde",
		config.EnvEscrowAddress:   testAddress,
	})

	_, err := config.Load()
	if !errors.Is(err, config.ErrUnknownAIProvider) {
		t.Fatalf("Load() error = %v, want ErrUnknownAIProvider", err)
	}
	if !strings.Contains(err.Error(), "clyde") {
		t.Errorf("error does not name the bad value: %v", err)
	}
	for _, want := range []string{config.ProviderAnthropic, config.ProviderOpenAI} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error does not list the valid value %q: %v", want, err)
		}
	}
}

// TestLoadStartBlockLookback covers the cold-start scan window override.
//
// The default is roughly three hours of Base Sepolia blocks, so a dispute
// older than that is invisible to a fresh agent unless this is raised — which
// is exactly the situation the override exists for.
func TestLoadStartBlockLookback(t *testing.T) {
	base := map[string]string{
		config.EnvPrivateKey:      testKey,
		config.EnvAnthropicAPIKey: testAPIKey,
		config.EnvEscrowAddress:   testAddress,
	}

	tests := []struct {
		name     string
		override string
		want     uint64
		wantErr  error
	}{
		{name: "unset falls back to the default", override: "", want: config.StartBlockLookback},
		{name: "explicit override is honoured", override: "20000", want: 20000},
		{name: "a single block is valid", override: "1", want: 1},
		{name: "zero is rejected", override: "0", wantErr: config.ErrInvalidStartBlockLookback},
		{name: "negative is rejected", override: "-5", wantErr: config.ErrInvalidStartBlockLookback},
		{name: "non-numeric is rejected", override: "lots", wantErr: config.ErrInvalidStartBlockLookback},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			env := make(map[string]string, len(base)+1)
			for k, v := range base {
				env[k] = v
			}
			env[config.EnvStartBlockLookback] = tt.override
			setEnv(t, env)

			cfg, err := config.Load()
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("Load() error = %v, want %v", err, tt.wantErr)
				}
				if !strings.Contains(err.Error(), tt.override) {
					t.Errorf("error does not name the bad value %q: %v", tt.override, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() unexpected error: %v", err)
			}
			if cfg.StartBlockLookback != tt.want {
				t.Errorf("StartBlockLookback = %d, want %d", cfg.StartBlockLookback, tt.want)
			}
		})
	}
}
