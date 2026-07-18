// Command agent is the AI arbiter for the ZK escrow demo on Base Sepolia.
//
// It polls the escrow contract for DisputeRaised evidence, asks Claude to
// weigh that evidence, and broadcasts the resulting ruling with `cast send`.
// All behaviour lives in internal packages; this file only wires stdio and
// signal handling to app.Run.
package main

import (
	"context"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/pigfox/zk-escrow/agent/internal/app"
)

// Injection seams so main() itself is exercised by a test without exiting the
// test binary or starting a real poll loop.
var (
	exit              = os.Exit
	run               = app.Run
	stdout  io.Writer = os.Stdout
	signals           = []os.Signal{syscall.SIGINT, syscall.SIGTERM}
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), signals...)
	defer stop()
	exit(run(ctx, stdout))
}
