package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"

	"github.com/ethereum/go-ethereum/common"
)

// Sentinel errors returned by Load. Callers should match with errors.Is.
var (
	// ErrMissingPrivateKey means PRIVATE_KEY was unset or empty.
	ErrMissingPrivateKey = errors.New("config: " + EnvPrivateKey + " is required")
	// ErrMissingAnthropicAPIKey means ANTHROPIC_API_KEY was unset or empty.
	ErrMissingAnthropicAPIKey = errors.New("config: " + EnvAnthropicAPIKey + " is required")
	// ErrInvalidEscrowAddress means ESCROW_ADDRESS was not a hex address.
	ErrInvalidEscrowAddress = errors.New("config: " + EnvEscrowAddress + " is not a valid address")
	// ErrInvalidRPCURL means RPC_URL was not a usable http(s) URL.
	ErrInvalidRPCURL = errors.New("config: " + EnvRPCURL + " is not a valid http(s) URL")
)

// Permitted RPC URL schemes.
const (
	schemeHTTP  = "http"
	schemeHTTPS = "https"
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
	// AnthropicAPIKey authenticates to the Messages API. Never logged.
	AnthropicAPIKey string
	// ChainID is always ChainID (Base Sepolia).
	ChainID int64
}

// Load reads and validates configuration from the environment.
//
// PRIVATE_KEY and ANTHROPIC_API_KEY are required. RPC_URL and ESCROW_ADDRESS
// fall back to their Default* constants. The chain id is not configurable: it
// is pinned to Base Sepolia so the agent structurally cannot broadcast to
// mainnet.
func Load() (Config, error) {
	privateKey := os.Getenv(EnvPrivateKey)
	if privateKey == "" {
		return Config{}, ErrMissingPrivateKey
	}

	apiKey := os.Getenv(EnvAnthropicAPIKey)
	if apiKey == "" {
		return Config{}, ErrMissingAnthropicAPIKey
	}

	rpcURL := DefaultRPCURL
	if override := os.Getenv(EnvRPCURL); override != "" {
		rpcURL = override
	}
	if err := validateRPCURL(rpcURL); err != nil {
		return Config{}, err
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
		AnthropicAPIKey: apiKey,
		ChainID:         ChainID,
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
