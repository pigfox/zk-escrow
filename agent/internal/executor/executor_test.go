package executor_test

import (
	"bytes"
	"context"
	"errors"
	"log"
	"math/big"
	"slices"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/escrow"
	"github.com/pigfox/zk-escrow/agent/internal/executor"
)

const (
	// realKey stands in for the operator's PRIVATE_KEY. It must never reach a log.
	realKey     = "0xdeadbeefcafebabe1234567890abcdefdeadbeefcafebabe1234567890abcdef"
	escrowHex   = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testRPCURL  = "https://sepolia.base.org"
	castSuccess = "transactionHash 0x123\nstatus 1 (success)"
)

// fakeRunner records its invocation and returns scripted results.
type fakeRunner struct {
	output []byte
	err    error

	calledName string
	calledArgs []string
	calls      int
}

func (f *fakeRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.calls++
	f.calledName = name
	f.calledArgs = slices.Clone(args)
	return f.output, f.err
}

func newExecutor(runner executor.CommandRunner, out *bytes.Buffer) *executor.Executor {
	return executor.New(runner, log.New(out, "", 0), config.Config{
		RPCURL:        testRPCURL,
		EscrowAddress: common.HexToAddress(escrowHex),
		PrivateKey:    realKey,
	})
}

// TestArgsComposition is the table-driven cast command composition suite.
func TestArgsComposition(t *testing.T) {
	tests := []struct {
		name     string
		escrowID *big.Int
		decision escrow.Decision
		key      string
		want     []string
	}{
		{
			name:     "buyer wins",
			escrowID: big.NewInt(0),
			decision: escrow.Decision{
				Ruling:     config.RulingBuyerWins,
				RulingName: config.RulingBuyerWinsString,
				Rationale:  "The seller never shipped.",
			},
			key: realKey,
			want: []string{
				"send",
				common.HexToAddress(escrowHex).Hex(),
				"resolveDispute(uint256,uint8,string)",
				"0",
				"0",
				"The seller never shipped.",
				"--rpc-url", testRPCURL,
				"--chain-id", "84532",
				"--private-key", realKey,
			},
		},
		{
			name:     "seller wins with a large escrow id",
			escrowID: new(big.Int).SetUint64(18446744073709551615),
			decision: escrow.Decision{
				Ruling:     config.RulingSellerWins,
				RulingName: config.RulingSellerWinsString,
				Rationale:  "Delivery is proven.",
			},
			key: realKey,
			want: []string{
				"send",
				common.HexToAddress(escrowHex).Hex(),
				"resolveDispute(uint256,uint8,string)",
				"18446744073709551615",
				"1",
				"Delivery is proven.",
				"--rpc-url", testRPCURL,
				"--chain-id", "84532",
				"--private-key", realKey,
			},
		},
		{
			name:     "redacted key is substituted verbatim",
			escrowID: big.NewInt(42),
			decision: escrow.Decision{
				Ruling:    config.RulingBuyerWins,
				Rationale: "Rationale with \"quotes\" and spaces.",
			},
			key: config.RedactedPlaceholder,
			want: []string{
				"send",
				common.HexToAddress(escrowHex).Hex(),
				"resolveDispute(uint256,uint8,string)",
				"42",
				"0",
				"Rationale with \"quotes\" and spaces.",
				"--rpc-url", testRPCURL,
				"--chain-id", "84532",
				"--private-key", config.RedactedPlaceholder,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			exe := newExecutor(&fakeRunner{}, &bytes.Buffer{})
			got := exe.Args(tt.escrowID, tt.decision, tt.key)
			if !slices.Equal(got, tt.want) {
				t.Errorf("Args() =\n%#v\nwant\n%#v", got, tt.want)
			}
		})
	}
}

// TestRedactedCommand is the table-driven rendering suite.
func TestRedactedCommand(t *testing.T) {
	tests := []struct {
		name        string
		decision    escrow.Decision
		wantContain []string
	}{
		{
			name: "simple rationale is unquoted where unambiguous",
			decision: escrow.Decision{
				Ruling:    config.RulingBuyerWins,
				Rationale: "Undelivered",
			},
			wantContain: []string{
				"cast send",
				"resolveDispute(uint256,uint8,string)",
				"--chain-id 84532",
				"--private-key " + config.RedactedPlaceholder,
				" Undelivered ",
			},
		},
		{
			name: "rationale with spaces is quoted",
			decision: escrow.Decision{
				Ruling:    config.RulingSellerWins,
				Rationale: "Tracking number 123 shows delivery.",
			},
			wantContain: []string{`"Tracking number 123 shows delivery."`},
		},
		{
			name: "rationale with quotes is escaped",
			decision: escrow.Decision{
				Ruling:    config.RulingBuyerWins,
				Rationale: `He said "it shipped"`,
			},
			wantContain: []string{`\"it shipped\"`},
		},
		{
			name: "empty rationale is rendered as an explicit empty argument",
			decision: escrow.Decision{
				Ruling:    config.RulingBuyerWins,
				Rationale: "",
			},
			wantContain: []string{`""`},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			exe := newExecutor(&fakeRunner{}, &bytes.Buffer{})
			got := exe.RedactedCommand(big.NewInt(1), tt.decision)
			for _, want := range tt.wantContain {
				if !strings.Contains(got, want) {
					t.Errorf("RedactedCommand() missing %q\ngot: %s", want, got)
				}
			}
			if strings.Contains(got, realKey) {
				t.Fatalf("RedactedCommand() leaked the private key: %s", got)
			}
		})
	}
}

// TestResolveNeverLogsThePrivateKey is the security assertion the spec calls
// for: the logged command carries the placeholder, the executed argv carries
// the real key, and the two never cross.
func TestResolveNeverLogsThePrivateKey(t *testing.T) {
	var logged bytes.Buffer
	runner := &fakeRunner{output: []byte(castSuccess)}
	exe := newExecutor(runner, &logged)

	decision := escrow.Decision{
		Ruling:     config.RulingSellerWins,
		RulingName: config.RulingSellerWinsString,
		Rationale:  "Tracking confirms delivery.",
	}

	output, err := exe.Resolve(t.Context(), big.NewInt(7), decision)
	if err != nil {
		t.Fatalf("Resolve() unexpected error: %v", err)
	}
	if output != castSuccess {
		t.Errorf("Resolve() = %q, want %q", output, castSuccess)
	}

	logText := logged.String()
	if strings.Contains(logText, realKey) {
		t.Fatalf("log leaked the private key:\n%s", logText)
	}
	if !strings.Contains(logText, config.RedactedPlaceholder) {
		t.Fatalf("log is missing %q:\n%s", config.RedactedPlaceholder, logText)
	}
	if !strings.Contains(logText, "cast send") {
		t.Fatalf("log is missing the cast command:\n%s", logText)
	}

	// The executed argv must carry the real key, not the placeholder.
	if runner.calledName != config.CastBinary {
		t.Errorf("ran %q, want %q", runner.calledName, config.CastBinary)
	}
	if !slices.Contains(runner.calledArgs, realKey) {
		t.Errorf("executed argv is missing the real key: %#v", runner.calledArgs)
	}
	if slices.Contains(runner.calledArgs, config.RedactedPlaceholder) {
		t.Errorf("executed argv contains the placeholder: %#v", runner.calledArgs)
	}
}

func TestResolveFailure(t *testing.T) {
	var logged bytes.Buffer
	runner := &fakeRunner{
		output: []byte("Error: insufficient funds"),
		err:    errors.New("exit status 1"),
	}
	exe := newExecutor(runner, &logged)

	output, err := exe.Resolve(t.Context(), big.NewInt(3), escrow.Decision{
		Ruling:    config.RulingBuyerWins,
		Rationale: "Refund owed.",
	})
	if !errors.Is(err, executor.ErrCastFailed) {
		t.Fatalf("Resolve() error = %v, want %v", err, executor.ErrCastFailed)
	}
	if !strings.Contains(output, "insufficient funds") {
		t.Errorf("Resolve() output = %q, want cast diagnostics", output)
	}
	if strings.Contains(err.Error(), realKey) {
		t.Fatalf("error text leaked the private key: %v", err)
	}
	if strings.Contains(logged.String(), realKey) {
		t.Fatalf("log leaked the private key:\n%s", logged.String())
	}
}

func TestNewUsesConfiguredDefaults(t *testing.T) {
	exe := newExecutor(&fakeRunner{}, &bytes.Buffer{})
	if exe.Binary != config.CastBinary {
		t.Errorf("Binary = %q, want %q", exe.Binary, config.CastBinary)
	}
	if exe.ChainID != config.ChainIDDecimal {
		t.Errorf("ChainID = %q, want %q", exe.ChainID, config.ChainIDDecimal)
	}
	if exe.RPCURL != testRPCURL {
		t.Errorf("RPCURL = %q, want %q", exe.RPCURL, testRPCURL)
	}
}

// TestExecRunner covers the real os/exec backed runner.
func TestExecRunner(t *testing.T) {
	t.Run("successful command returns combined output", func(t *testing.T) {
		out, err := executor.ExecRunner{}.Run(t.Context(), "echo", "hello")
		if err != nil {
			t.Fatalf("Run() unexpected error: %v", err)
		}
		if strings.TrimSpace(string(out)) != "hello" {
			t.Errorf("Run() = %q, want %q", string(out), "hello")
		}
	})

	t.Run("missing binary reports an error", func(t *testing.T) {
		_, err := executor.ExecRunner{}.Run(
			t.Context(), "definitely-not-a-real-binary-zk-escrow")
		if err == nil {
			t.Fatal("Run() expected an error for a missing binary")
		}
	})
}
