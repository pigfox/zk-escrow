package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

// Sentinel errors returned by Load. Callers should match with errors.Is.
var (
	// ErrMissingPrivateKey means PRIVATE_KEY was unset or empty.
	ErrMissingPrivateKey = errors.New("config: " + EnvPrivateKey + " is required")
	// ErrMissingAnthropicAPIKey means ANTHROPIC_API_KEY was unset or empty
	// while the Anthropic provider was selected.
	ErrMissingAnthropicAPIKey = errors.New("config: " + EnvAnthropicAPIKey +
		" is required when " + EnvAIProvider + "=" + ProviderAnthropic)
	// ErrMissingOpenAIAPIKey means OPENAI_API_KEY was unset or empty while the
	// OpenAI provider was selected.
	ErrMissingOpenAIAPIKey = errors.New("config: " + EnvOpenAIAPIKey +
		" is required when " + EnvAIProvider + "=" + ProviderOpenAI)
	// ErrUnknownAIProvider means AI_PROVIDER was set to something unsupported.
	ErrUnknownAIProvider = errors.New("config: " + EnvAIProvider +
		" must be " + ProviderAnthropic + " or " + ProviderOpenAI)
	// ErrInvalidEscrowAddress means ESCROW_ADDRESS was not a hex address.
	ErrInvalidEscrowAddress = errors.New("config: " + EnvEscrowAddress + " is not a valid address")
	// ErrInvalidStartBlockLookback means START_BLOCK_LOOKBACK was not a
	// positive integer.
	ErrInvalidStartBlockLookback = errors.New("config: " + EnvStartBlockLookback +
		" must be a positive whole number of blocks")
	// ErrInvalidRPCURL means RPC_URL was not a usable http(s) URL.
	ErrInvalidRPCURL = errors.New("config: " + EnvRPCURL + " is not a valid http(s) URL")
)

// Permitted RPC URL schemes.
const (
	schemeHTTP  = "http"
	schemeHTTPS = "https"

	// Parsing parameters for START_BLOCK_LOOKBACK.
	decimalBase = 10
	bitSize64   = 64
)

// Config is the fully validated runtime configuration. Every field is derived
// from the process environment; nothing is read from disk.
type Config struct {
	// RPCURL is the Base Sepolia JSON-RPC endpoint.
	RPCURL string
	// EscrowAddress is the EscrowUpgradeable proxy.
	EscrowAddress common.Address
	// PrivateKey signs resolveDispute transactions. Never logged.
	PrivateKey string
	// AIProvider selects the reasoning backend: ProviderAnthropic or
	// ProviderOpenAI.
	AIProvider string
	// AnthropicAPIKey authenticates to the Messages API. Never logged.
	// Empty unless AIProvider is ProviderAnthropic.
	AnthropicAPIKey string
	// OpenAIAPIKey authenticates to the Chat Completions API. Never logged.
	// Empty unless AIProvider is ProviderOpenAI.
	OpenAIAPIKey string
	// StartBlockLookback is how far behind head a cold start begins scanning.
	StartBlockLookback uint64
	// ChainID is always ChainID (Base Sepolia).
	ChainID int64
}

// Load reads and validates configuration from the environment.
//
// PRIVATE_KEY is always required. Exactly one model API key is required — the
// one belonging to the selected AI_PROVIDER — so an operator running against
// OpenAI is not asked for an Anthropic key they do not have. RPC_URL and
// ESCROW_ADDRESS fall back to their Default* constants. The chain id is not
// configurable: it is pinned to Base Sepolia so the agent structurally cannot
// broadcast to mainnet.
func Load() (Config, error) {
	privateKey := os.Getenv(EnvPrivateKey)
	if privateKey == "" {
		return Config{}, ErrMissingPrivateKey
	}

	provider := DefaultAIProvider
	if override := os.Getenv(EnvAIProvider); override != "" {
		provider = strings.ToLower(strings.TrimSpace(override))
	}

	// Fail at startup rather than on the first dispute: an agent that polls
	// happily for an hour and only then discovers it cannot reason is worse
	// than one that refuses to start.
	var anthropicKey, openAIKey string
	switch provider {
	case ProviderAnthropic:
		anthropicKey = os.Getenv(EnvAnthropicAPIKey)
		if anthropicKey == "" {
			return Config{}, ErrMissingAnthropicAPIKey
		}
	case ProviderOpenAI:
		openAIKey = os.Getenv(EnvOpenAIAPIKey)
		if openAIKey == "" {
			return Config{}, ErrMissingOpenAIAPIKey
		}
	default:
		return Config{}, fmt.Errorf("%w: got %q", ErrUnknownAIProvider, provider)
	}

	rpcURL := DefaultRPCURL
	if override := os.Getenv(EnvRPCURL); override != "" {
		rpcURL = override
	}
	if err := validateRPCURL(rpcURL); err != nil {
		return Config{}, err
	}

	lookback := StartBlockLookback
	if override := os.Getenv(EnvStartBlockLookback); override != "" {
		parsed, err := strconv.ParseUint(override, decimalBase, bitSize64)
		if err != nil || parsed == 0 {
			return Config{}, fmt.Errorf("%w: got %q", ErrInvalidStartBlockLookback, override)
		}
		lookback = parsed
	}

	escrowAddress := DefaultEscrowAddress
	if override := os.Getenv(EnvEscrowAddress); override != "" {
		escrowAddress = override
	}
	if !common.IsHexAddress(escrowAddress) {
		return Config{}, fmt.Errorf("%w: %q", ErrInvalidEscrowAddress, escrowAddress)
	}

	return Config{
		RPCURL:          rpcURL,
		EscrowAddress:   common.HexToAddress(escrowAddress),
		PrivateKey:      privateKey,
		AIProvider:      provider,
		AnthropicAPIKey: anthropicKey,
		OpenAIAPIKey:    openAIKey,

		StartBlockLookback: lookback,
		ChainID:            ChainID,
	}, nil
}

// validateRPCURL rejects anything that is not an absolute http or https URL.
func validateRPCURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("%w: %q: %w", ErrInvalidRPCURL, raw, err)
	}
	if parsed.Scheme != schemeHTTP && parsed.Scheme != schemeHTTPS {
		return fmt.Errorf("%w: %q: scheme must be %s or %s",
			ErrInvalidRPCURL, raw, schemeHTTP, schemeHTTPS)
	}
	if parsed.Host == "" {
		return fmt.Errorf("%w: %q: missing host", ErrInvalidRPCURL, raw)
	}
	return nil
}
