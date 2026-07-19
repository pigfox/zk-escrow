package arbiter_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"math/big"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/pigfox/zk-escrow/agent/internal/arbiter"
	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/escrow"
)

const goodReply = `{"ruling":"BuyerWins","rationale":"The seller never shipped."}`

var buyer = common.HexToAddress("0x1111111111111111111111111111111111111111")

// syncBuffer is a bytes.Buffer safe for concurrent writes and reads, so the
// poll loop can log from its goroutine while the test inspects the output.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// fakeReader is a scripted Reader, guarded so the poll loop goroutine and the
// test can touch it concurrently.
type fakeReader struct {
	mu sync.Mutex

	head       uint64
	headErr    error
	disputes   []escrow.Dispute
	disputes2  []escrow.Dispute
	disputeErr error
	state      uint8
	stateErr   error

	ranges   [][2]uint64
	calls    int
	stateFor []string
}

func (f *fakeReader) HeadBlock(context.Context) (uint64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.head, f.headErr
}

// setHeadErr makes subsequent polls fail.
func (f *fakeReader) setHeadErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.headErr = err
}

func (f *fakeReader) Disputes(_ context.Context, from, to uint64) ([]escrow.Dispute, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ranges = append(f.ranges, [2]uint64{from, to})
	f.calls++
	if f.disputeErr != nil {
		return nil, f.disputeErr
	}
	if f.calls > 1 && f.disputes2 != nil {
		return f.disputes2, nil
	}
	return f.disputes, nil
}

func (f *fakeReader) State(_ context.Context, escrowID *big.Int) (uint8, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stateFor = append(f.stateFor, escrowID.String())
	return f.state, f.stateErr
}

// fakeModel is a scripted ai.Client.
type fakeModel struct {
	reply   string
	err     error
	prompts []string
}

func (f *fakeModel) Complete(_ context.Context, _, userPrompt string) (string, error) {
	f.prompts = append(f.prompts, userPrompt)
	return f.reply, f.err
}

// fakeResolver is a scripted Resolver.
type fakeResolver struct {
	mu        sync.Mutex
	output    string
	err       error
	decisions []escrow.Decision
	ids       []string
}

func (f *fakeResolver) Resolve(
	_ context.Context, escrowID *big.Int, decision escrow.Decision,
) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ids = append(f.ids, escrowID.String())
	f.decisions = append(f.decisions, decision)
	return f.output, f.err
}

// decisionCount reports how many rulings have been broadcast.
func (f *fakeResolver) decisionCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.decisions)
}

// manualTicker fires exactly when the test says so.
type manualTicker struct {
	ch      chan time.Time
	mu      sync.Mutex
	stopped bool
}

func newManualTicker() *manualTicker {
	return &manualTicker{ch: make(chan time.Time, 1)}
}

func (m *manualTicker) C() <-chan time.Time { return m.ch }
func (m *manualTicker) Stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopped = true
}

// wasStopped reports whether Stop has been called.
func (m *manualTicker) wasStopped() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.stopped
}
func (m *manualTicker) tick() { m.ch <- time.Now() }

// oneDispute is the standard single-escrow, two-submission fixture.
func oneDispute() []escrow.Dispute {
	return []escrow.Dispute{{
		EscrowID: big.NewInt(7),
		Submissions: []escrow.Submission{
			{RaisedBy: buyer, Evidence: "Nothing arrived."},
			{RaisedBy: buyer, Evidence: "Still nothing."},
		},
	}}
}

func newArbiter(r arbiter.Reader, m *fakeModel, res arbiter.Resolver, out io.Writer,
) *arbiter.Arbiter {
	return arbiter.New(r, m, res, log.New(out, "", 0))
}

// TestPollSettlesDispute is the end-to-end happy path.
func TestPollSettlesDispute(t *testing.T) {
	var out bytes.Buffer
	reader := &fakeReader{head: 102, disputes: oneDispute(), state: config.StateDisputed}
	model := &fakeModel{reply: goodReply}
	resolver := &fakeResolver{output: "status 1 (success)"}

	arb := newArbiter(reader, model, resolver, &out)
	if err := arb.Poll(t.Context()); err != nil {
		t.Fatalf("Poll() unexpected error: %v", err)
	}

	if len(resolver.decisions) != 1 {
		t.Fatalf("got %d rulings broadcast, want 1", len(resolver.decisions))
	}
	if resolver.decisions[0].Ruling != config.RulingBuyerWins {
		t.Errorf("ruling = %d, want %d", resolver.decisions[0].Ruling, config.RulingBuyerWins)
	}
	if resolver.ids[0] != "7" {
		t.Errorf("resolved escrow %s, want 7", resolver.ids[0])
	}

	// Both submissions must reach the model in a single prompt.
	if len(model.prompts) != 1 {
		t.Fatalf("model called %d times, want 1", len(model.prompts))
	}
	for _, want := range []string{"Nothing arrived.", "Still nothing."} {
		if !strings.Contains(model.prompts[0], want) {
			t.Errorf("prompt missing %q", want)
		}
	}

	// State must be checked before ruling.
	if len(reader.stateFor) != 1 || reader.stateFor[0] != "7" {
		t.Errorf("state checked for %v, want [7]", reader.stateFor)
	}
}

// TestPollBlockWindows covers the scan-window arithmetic.
func TestPollBlockWindows(t *testing.T) {
	tests := []struct {
		name      string
		head      uint64
		wantRange [2]uint64
		wantScan  bool
	}{
		{
			name:     "head at or below the confirmation depth scans nothing",
			head:     config.BlockConfirmations,
			wantScan: false,
		},
		{
			name:      "shallow chain starts from block 1 and stops at the safe head",
			head:      102,
			wantRange: [2]uint64{1, 100},
			wantScan:  true,
		},
		{
			name: "deep chain starts a lookback behind and is chunk limited",
			head: 10000,
			wantRange: [2]uint64{
				10000 - config.BlockConfirmations - config.StartBlockLookback,
				10000 - config.BlockConfirmations - config.StartBlockLookback +
					config.BlockRangeChunkSize - 1,
			},
			wantScan: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			reader := &fakeReader{head: tt.head, state: config.StateDisputed}
			arb := newArbiter(reader, &fakeModel{}, &fakeResolver{}, &bytes.Buffer{})

			if err := arb.Poll(t.Context()); err != nil {
				t.Fatalf("Poll() unexpected error: %v", err)
			}

			if !tt.wantScan {
				if len(reader.ranges) != 0 {
					t.Fatalf("scanned %v, want no scan", reader.ranges)
				}
				return
			}
			if len(reader.ranges) != 1 {
				t.Fatalf("scanned %d ranges, want 1", len(reader.ranges))
			}
			if reader.ranges[0] != tt.wantRange {
				t.Errorf("range = %v, want %v", reader.ranges[0], tt.wantRange)
			}
		})
	}
}

// TestPollAdvancesAndStalls checks that the cursor moves forward and that a
// second poll against an unchanged head does no work.
func TestPollAdvancesAndStalls(t *testing.T) {
	reader := &fakeReader{head: 102, disputes2: []escrow.Dispute{}}
	arb := newArbiter(reader, &fakeModel{}, &fakeResolver{}, &bytes.Buffer{})

	if err := arb.Poll(t.Context()); err != nil {
		t.Fatalf("first Poll() unexpected error: %v", err)
	}
	if err := arb.Poll(t.Context()); err != nil {
		t.Fatalf("second Poll() unexpected error: %v", err)
	}
	if len(reader.ranges) != 1 {
		t.Fatalf("scanned %v, want a single range (cursor past the safe head)", reader.ranges)
	}

	// Once the chain advances, scanning resumes from the cursor.
	reader.head = 200
	if err := arb.Poll(t.Context()); err != nil {
		t.Fatalf("third Poll() unexpected error: %v", err)
	}
	if len(reader.ranges) != 2 {
		t.Fatalf("scanned %v, want two ranges", reader.ranges)
	}
	if reader.ranges[1] != [2]uint64{101, 198} {
		t.Errorf("second range = %v, want [101 198]", reader.ranges[1])
	}
}

func TestPollErrors(t *testing.T) {
	headErr := errors.New("rpc unavailable")
	logsErr := errors.New("query returned more than 10000 results")

	t.Run("head block failure", func(t *testing.T) {
		reader := &fakeReader{headErr: headErr}
		arb := newArbiter(reader, &fakeModel{}, &fakeResolver{}, &bytes.Buffer{})
		if err := arb.Poll(t.Context()); !errors.Is(err, headErr) {
			t.Fatalf("Poll() error = %v, want %v", err, headErr)
		}
	})

	t.Run("log query failure", func(t *testing.T) {
		reader := &fakeReader{head: 102, disputeErr: logsErr}
		arb := newArbiter(reader, &fakeModel{}, &fakeResolver{}, &bytes.Buffer{})
		if err := arb.Poll(t.Context()); !errors.Is(err, logsErr) {
			t.Fatalf("Poll() error = %v, want %v", err, logsErr)
		}
	})
}

// TestSettleFailuresAreLoggedNotFatal covers every per-escrow failure: the
// poll must survive them and advance its cursor.
func TestSettleFailuresAreLoggedNotFatal(t *testing.T) {
	tests := []struct {
		name        string
		reader      *fakeReader
		model       *fakeModel
		resolver    *fakeResolver
		wantLog     string
		wantResolve bool
	}{
		{
			name: "state lookup fails",
			reader: &fakeReader{
				head: 102, disputes: oneDispute(),
				stateErr: errors.New("execution reverted"),
			},
			model:    &fakeModel{reply: goodReply},
			resolver: &fakeResolver{},
			wantLog:  "execution reverted",
		},
		{
			name: "escrow already resolved is skipped",
			reader: &fakeReader{
				head: 102, disputes: oneDispute(), state: config.StateResolved,
			},
			model:    &fakeModel{reply: goodReply},
			resolver: &fakeResolver{},
			wantLog:  "not Disputed",
		},
		{
			name: "escrow still funded is skipped",
			reader: &fakeReader{
				head: 102, disputes: oneDispute(), state: config.StateFunded,
			},
			model:    &fakeModel{reply: goodReply},
			resolver: &fakeResolver{},
			wantLog:  "not Disputed",
		},
		{
			name: "model call fails",
			reader: &fakeReader{
				head: 102, disputes: oneDispute(), state: config.StateDisputed,
			},
			model:    &fakeModel{err: errors.New("rate limited")},
			resolver: &fakeResolver{},
			wantLog:  "rate limited",
		},
		{
			name: "model returns an unparseable ruling",
			reader: &fakeReader{
				head: 102, disputes: oneDispute(), state: config.StateDisputed,
			},
			model:    &fakeModel{reply: `{"ruling":"CoinFlip","rationale":"heads"}`},
			resolver: &fakeResolver{},
			wantLog:  "unknown ruling",
		},
		{
			name: "broadcast fails",
			reader: &fakeReader{
				head: 102, disputes: oneDispute(), state: config.StateDisputed,
			},
			model:       &fakeModel{reply: goodReply},
			resolver:    &fakeResolver{err: errors.New("insufficient funds")},
			wantLog:     "insufficient funds",
			wantResolve: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out bytes.Buffer
			arb := newArbiter(tt.reader, tt.model, tt.resolver, &out)

			if err := arb.Poll(t.Context()); err != nil {
				t.Fatalf("Poll() must not fail on a per-escrow error, got %v", err)
			}
			if !strings.Contains(out.String(), tt.wantLog) {
				t.Errorf("log missing %q:\n%s", tt.wantLog, out.String())
			}
			if got := len(tt.resolver.decisions) > 0; got != tt.wantResolve {
				t.Errorf("resolve attempted = %v, want %v", got, tt.wantResolve)
			}
		})
	}
}

func TestRunStopsOnContextCancellation(t *testing.T) {
	var out syncBuffer
	ctx, cancel := context.WithCancel(t.Context())
	ticker := newManualTicker()
	arb := newArbiter(&fakeReader{head: 102}, &fakeModel{}, &fakeResolver{}, &out)

	done := make(chan struct{})
	go func() {
		defer close(done)
		arb.Run(ctx, ticker)
	}()

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run() did not return after cancellation")
	}

	if !ticker.wasStopped() {
		t.Error("Run() must stop the ticker on the way out")
	}
	if !strings.Contains(out.String(), "shutdown") {
		t.Errorf("log missing shutdown notice:\n%s", out.String())
	}
}

func TestRunPollsOnTickAndLogsPollErrors(t *testing.T) {
	var out syncBuffer
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	reader := &fakeReader{head: 102, disputes: oneDispute(), state: config.StateDisputed}
	resolver := &fakeResolver{output: "ok"}
	arb := newArbiter(reader, &fakeModel{reply: goodReply}, resolver, &out)

	ticker := newManualTicker()
	done := make(chan struct{})
	go func() {
		defer close(done)
		arb.Run(ctx, ticker)
	}()

	// First tick: a successful poll that settles the dispute.
	ticker.tick()
	waitFor(t, func() bool { return resolver.decisionCount() == 1 })

	// Second tick: a failing poll, which must be logged without stopping.
	reader.setHeadErr(errors.New("node restarting"))
	ticker.tick()
	waitFor(t, func() bool { return strings.Contains(out.String(), "node restarting") })

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run() did not return after cancellation")
	}
}

// waitFor polls a condition with a short timeout, avoiding fixed sleeps.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition not met within the timeout")
}

func TestRealTicker(t *testing.T) {
	ticker := arbiter.NewRealTicker(time.Millisecond)
	defer ticker.Stop()

	select {
	case <-ticker.C():
	case <-time.After(2 * time.Second):
		t.Fatal("RealTicker did not fire")
	}
}

// TestPollLookbackOverride covers the configurable cold-start window.
//
// This exists because of a real miss: with the default 5000-block lookback a
// fresh agent began scanning ten blocks past a live dispute and never saw it.
// Raising the window is how an operator catches up on disputes older than the
// default, so the override has to actually move the first scanned block.
func TestPollLookbackOverride(t *testing.T) {
	const head = 100_000

	tests := []struct {
		name      string
		lookback  uint64
		wantFirst uint64
	}{
		{
			name:      "zero falls back to the compiled default",
			lookback:  0,
			wantFirst: head - config.BlockConfirmations - config.StartBlockLookback,
		},
		{
			name:      "a wider window starts further back",
			lookback:  50_000,
			wantFirst: head - config.BlockConfirmations - 50_000,
		},
		{
			name:      "a narrower window starts closer to head",
			lookback:  10,
			wantFirst: head - config.BlockConfirmations - 10,
		},
		{
			name:      "a window deeper than the chain clamps to block 1",
			lookback:  head * 2,
			wantFirst: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			reader := &fakeReader{head: head, state: config.StateDisputed}
			arb := newArbiter(reader, &fakeModel{}, &fakeResolver{}, &bytes.Buffer{})
			arb.Lookback = tt.lookback

			if err := arb.Poll(t.Context()); err != nil {
				t.Fatalf("Poll() unexpected error: %v", err)
			}
			if len(reader.ranges) != 1 {
				t.Fatalf("scanned %d ranges, want 1", len(reader.ranges))
			}
			if got := reader.ranges[0][0]; got != tt.wantFirst {
				t.Errorf("first scanned block = %d, want %d", got, tt.wantFirst)
			}
		})
	}
}
