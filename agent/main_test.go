package main

import (
	"bytes"
	"context"
	"io"
	"testing"

	"github.com/pigfox/zk-escrow/agent/internal/config"
)

// TestMain_DelegatesToApp exercises main() itself: the real os.Exit and
// app.Run are swapped for recorders so the test binary survives and no poll
// loop starts.
func TestMain_DelegatesToApp(t *testing.T) {
	origExit, origRun, origStdout := exit, run, stdout
	t.Cleanup(func() { exit, run, stdout = origExit, origRun, origStdout })

	var out bytes.Buffer
	var gotCode int
	var exitCalls int
	var gotWriter io.Writer
	var ctxSeen context.Context
	var ctxLiveAtHandOff bool

	exit = func(code int) {
		exitCalls++
		gotCode = code
	}
	run = func(ctx context.Context, w io.Writer) int {
		ctxSeen = ctx
		// The signal context must still be live while Run is executing; it is
		// only released by main's deferred stop().
		ctxLiveAtHandOff = ctx.Err() == nil
		gotWriter = w
		return config.ExitConfigError
	}
	stdout = &out

	main()

	if exitCalls != 1 {
		t.Fatalf("os.Exit called %d times, want 1", exitCalls)
	}
	if gotCode != config.ExitConfigError {
		t.Errorf("exit code = %d, want %d", gotCode, config.ExitConfigError)
	}
	if gotWriter != io.Writer(&out) {
		t.Error("app.Run must receive the configured stdout writer")
	}
	if ctxSeen == nil {
		t.Fatal("app.Run must receive a context")
	}
	if !ctxLiveAtHandOff {
		t.Error("the signal context must be live while app.Run executes")
	}
	if err := ctxSeen.Err(); err == nil {
		t.Error("main's deferred stop() must release the signal context on return")
	}
}

// TestSignalsAreRegistered guards the shutdown contract.
func TestSignalsAreRegistered(t *testing.T) {
	if len(signals) != 2 {
		t.Fatalf("registered %d signals, want 2 (SIGINT, SIGTERM)", len(signals))
	}
}
