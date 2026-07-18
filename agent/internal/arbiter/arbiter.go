// Package arbiter drives the poll loop: it scans for DisputeRaised evidence,
// asks the model for a ruling, and broadcasts that ruling on chain.
package arbiter

import (
	"context"
	"log"
	"math/big"
	"time"

	"github.com/pigfox/zk-escrow/agent/internal/ai"
	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/escrow"
)

// Reader is the arbiter's view of the chain.
type Reader interface {
	// HeadBlock returns the current head block number.
	HeadBlock(ctx context.Context) (uint64, error)
	// Disputes returns DisputeRaised submissions grouped by escrow id.
	Disputes(ctx context.Context, from, to uint64) ([]escrow.Dispute, error)
	// State returns an escrow's lifecycle state.
	State(ctx context.Context, escrowID *big.Int) (uint8, error)
}

// Resolver broadcasts a ruling.
type Resolver interface {
	// Resolve writes the decision on chain and returns the tool's output.
	Resolve(ctx context.Context, escrowID *big.Int, decision escrow.Decision) (string, error)
}

// Ticker abstracts time.Ticker so the poll loop is testable without sleeping.
type Ticker interface {
	// C is the tick channel.
	C() <-chan time.Time
	// Stop releases the ticker's resources.
	Stop()
}

// RealTicker adapts time.Ticker to Ticker.
type RealTicker struct {
	ticker *time.Ticker
}

// NewRealTicker returns a Ticker that fires every d.
func NewRealTicker(d time.Duration) *RealTicker {
	return &RealTicker{ticker: time.NewTicker(d)}
}

// C is the tick channel.
func (r *RealTicker) C() <-chan time.Time { return r.ticker.C }

// Stop releases the ticker's resources.
func (r *RealTicker) Stop() { r.ticker.Stop() }

// Arbiter polls for disputes and settles them.
type Arbiter struct {
	// Reader supplies logs and state.
	Reader Reader
	// Model produces rulings.
	Model ai.Client
	// Resolver broadcasts rulings.
	Resolver Resolver
	// Logger receives progress and errors. Never receives a secret.
	Logger *log.Logger

	// nextBlock is the first block of the next scan window. Zero means the
	// arbiter has not yet chosen a starting point.
	nextBlock uint64
}

// New builds an Arbiter.
func New(reader Reader, model ai.Client, resolver Resolver, logger *log.Logger) *Arbiter {
	return &Arbiter{Reader: reader, Model: model, Resolver: resolver, Logger: logger}
}

// Run polls on every tick until ctx is cancelled. Poll errors are logged and
// the loop continues; only cancellation stops it, so there is nothing to
// return.
func (a *Arbiter) Run(ctx context.Context, ticker Ticker) {
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			a.Logger.Print(config.LogShutdown)
			return
		case <-ticker.C():
			if err := a.Poll(ctx); err != nil {
				a.Logger.Printf(config.LogPollError, err)
			}
		}
	}
}

// Poll scans one bounded block range and settles every dispute it finds.
func (a *Arbiter) Poll(ctx context.Context) error {
	head, err := a.Reader.HeadBlock(ctx)
	if err != nil {
		return err
	}

	// Stay behind head so a reorg cannot invalidate a ruling.
	if head <= config.BlockConfirmations {
		return nil
	}
	safe := head - config.BlockConfirmations

	if a.nextBlock == 0 {
		if safe > config.StartBlockLookback {
			a.nextBlock = safe - config.StartBlockLookback
		} else {
			a.nextBlock = 1
		}
	}

	if a.nextBlock > safe {
		return nil
	}

	from := a.nextBlock
	to := min(from+config.BlockRangeChunkSize-1, safe)
	a.Logger.Printf(config.LogScanning, from, to)

	disputes, err := a.Reader.Disputes(ctx, from, to)
	if err != nil {
		return err
	}

	for _, dispute := range disputes {
		if err := a.settle(ctx, dispute); err != nil {
			a.Logger.Printf(config.LogEscrowError, dispute.EscrowID.String(), err)
		}
	}

	a.nextBlock = to + 1
	return nil
}

// settle asks the model for a ruling and broadcasts it, unless the escrow has
// already left the Disputed state.
func (a *Arbiter) settle(ctx context.Context, dispute escrow.Dispute) error {
	id := dispute.EscrowID.String()
	a.Logger.Printf(config.LogDisputeFound, id, len(dispute.Submissions))

	state, err := a.Reader.State(ctx, dispute.EscrowID)
	if err != nil {
		return err
	}
	if state != config.StateDisputed {
		a.Logger.Printf(config.LogSkippingNotDisputed, id, state, config.StateDisputed)
		return nil
	}

	raw, err := a.Model.Complete(ctx, config.SystemPrompt, ai.BuildPrompt(dispute))
	if err != nil {
		return err
	}

	decision, err := ai.ParseDecision(raw)
	if err != nil {
		return err
	}
	a.Logger.Printf(config.LogRuling, id, decision.RulingName, decision.Ruling)

	output, err := a.Resolver.Resolve(ctx, dispute.EscrowID, decision)
	if err != nil {
		return err
	}
	a.Logger.Printf(config.LogExecuted, id, output)
	return nil
}
