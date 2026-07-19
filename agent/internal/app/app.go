// Package app wires the configuration, chain reader, model client and
// transaction executor together and runs the arbiter loop. It exists so that
// package main stays a one-line shell.
package app

import (
	"context"
	"io"
	"log"
	"net/http"

	"github.com/ethereum/go-ethereum/ethclient"

	"github.com/pigfox/zk-escrow/agent/internal/ai"
	"github.com/pigfox/zk-escrow/agent/internal/arbiter"
	"github.com/pigfox/zk-escrow/agent/internal/chain"
	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/executor"
)

// nodeClient is a chain.EthClient that also owns a connection to close.
type nodeClient interface {
	chain.EthClient
	// Close releases the underlying RPC connection.
	Close()
}

// dialer opens an RPC connection.
type dialer func(ctx context.Context, rawURL string) (nodeClient, error)

// Seams overridden by tests so every failure branch below is reachable
// without a network or a foundry install.
var (
	// dial opens the JSON-RPC connection.
	dial dialer = defaultDial
	// escrowABI is the ABI the chain reader is built from.
	escrowABI = config.EscrowABIJSON
	// newTicker produces the poll loop's clock.
	newTicker = func() arbiter.Ticker { return arbiter.NewRealTicker(config.PollInterval) }
)

// defaultDial is the production dialer. Base Sepolia is reached over HTTP, so
// this establishes no socket until the first request.
func defaultDial(ctx context.Context, rawURL string) (nodeClient, error) {
	return ethclient.DialContext(ctx, rawURL)
}

// newModelClient builds the reasoning backend the operator selected, and
// returns it alongside the model name for the startup banner.
//
// config.Load has already rejected any provider other than these two and
// verified that the selected one has a key, so there is no unknown-provider
// case left to handle here.
func newModelClient(cfg config.Config) (client ai.Client, modelName string) {
	if cfg.AIProvider == config.ProviderOpenAI {
		return ai.NewOpenAIClient(cfg.OpenAIAPIKey, &http.Client{
			Timeout: config.OpenAITimeout,
		}), config.OpenAIModel
	}
	return ai.NewHTTPClient(cfg.AnthropicAPIKey, &http.Client{
		Timeout: config.AnthropicTimeout,
	}), config.AnthropicModel
}

// Run loads configuration, builds the arbiter and polls until ctx is
// cancelled. It returns the process exit code.
func Run(ctx context.Context, out io.Writer) int {
	logger := log.New(out, config.LogPrefix, config.LogFlags)

	cfg, err := config.Load()
	if err != nil {
		logger.Print(err)
		return config.ExitConfigError
	}

	client, err := dial(ctx, cfg.RPCURL)
	if err != nil {
		logger.Print(err)
		return config.ExitDialError
	}
	defer client.Close()

	reader, err := chain.New(client, cfg.EscrowAddress, escrowABI)
	if err != nil {
		logger.Print(err)
		return config.ExitChainError
	}

	model, modelName := newModelClient(cfg)
	resolver := executor.New(executor.ExecRunner{}, logger, cfg)

	logger.Printf(config.LogStarting,
		cfg.RPCURL, cfg.EscrowAddress.Hex(), cfg.ChainID, modelName)

	judge := arbiter.New(reader, model, resolver, logger)
	judge.Lookback = cfg.StartBlockLookback
	judge.Run(ctx, newTicker())
	return config.ExitOK
}
