// Package executor composes and runs the `cast send` command that writes the
// arbiter's ruling on chain.
//
// The private key is present in exactly one place: the argv slice handed to
// the CommandRunner. Every rendering intended for a human or a log replaces it
// with config.RedactedPlaceholder.
package executor

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/big"
	"os/exec"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/common"

	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/escrow"
)

// ErrCastFailed means the cast invocation did not exit cleanly.
var ErrCastFailed = errors.New("executor: cast send failed")

// CommandRunner runs an external binary and returns its combined output.
type CommandRunner interface {
	// Run executes name with args and returns combined stdout and stderr.
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
}

// ExecRunner is the real CommandRunner, backed by os/exec.
type ExecRunner struct{}

// Run executes the command, returning combined output even on failure so the
// caller can surface cast's own diagnostics.
func (ExecRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// Executor broadcasts resolveDispute transactions via cast.
type Executor struct {
	// Runner performs the invocation.
	Runner CommandRunner
	// Logger records the redacted command before it runs.
	Logger *log.Logger
	// Binary is the cast executable name.
	Binary string
	// RPCURL is passed to --rpc-url.
	RPCURL string
	// ChainID is passed to --chain-id.
	ChainID string
	// Escrow is the contract the transaction targets.
	Escrow common.Address
	// PrivateKey signs the transaction. Never logged.
	PrivateKey string
}

// New builds an Executor from validated configuration.
func New(runner CommandRunner, logger *log.Logger, cfg config.Config) *Executor {
	return &Executor{
		Runner:     runner,
		Logger:     logger,
		Binary:     config.CastBinary,
		RPCURL:     cfg.RPCURL,
		ChainID:    config.ChainIDDecimal,
		Escrow:     cfg.EscrowAddress,
		PrivateKey: cfg.PrivateKey,
	}
}

// Args builds the argv for a ruling. The key argument is substituted verbatim,
// so pass config.RedactedPlaceholder to produce a loggable form and the real
// key to produce an executable one.
func (e *Executor) Args(escrowID *big.Int, decision escrow.Decision, key string) []string {
	return []string{
		config.CastSend,
		e.Escrow.Hex(),
		config.ResolveDisputeSignature,
		escrowID.Text(config.DecimalBase),
		strconv.FormatUint(uint64(decision.Ruling), config.DecimalBase),
		decision.Rationale,
		config.CastFlagRPCURL, e.RPCURL,
		config.CastFlagChainID, e.ChainID,
		config.CastFlagPrivateKey, key,
	}
}

// RedactedCommand renders the full command line with the private key replaced
// by config.RedactedPlaceholder. This is the only form that may be logged.
func (e *Executor) RedactedCommand(escrowID *big.Int, decision escrow.Decision) string {
	parts := append([]string{e.Binary},
		e.Args(escrowID, decision, config.RedactedPlaceholder)...)
	quoted := make([]string, len(parts))
	for i, part := range parts {
		quoted[i] = quoteArg(part)
	}
	return strings.Join(quoted, " ")
}

// quoteArg quotes an argument only when it would otherwise be ambiguous on a
// shell command line.
func quoteArg(arg string) string {
	if arg == "" || strings.ContainsAny(arg, " \t\n\"'\\") {
		return strconv.Quote(arg)
	}
	return arg
}

// Resolve logs the redacted command, then runs the real one. It returns cast's
// combined output.
func (e *Executor) Resolve(
	ctx context.Context, escrowID *big.Int, decision escrow.Decision,
) (string, error) {
	e.Logger.Printf(config.LogExecuting, e.RedactedCommand(escrowID, decision))

	output, err := e.Runner.Run(ctx, e.Binary, e.Args(escrowID, decision, e.PrivateKey)...)
	if err != nil {
		return string(output), fmt.Errorf("%w: %w: %s", ErrCastFailed, err, string(output))
	}
	return string(output), nil
}
