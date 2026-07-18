package config_test

import (
	"errors"
	"testing"

	"github.com/pigfox/zk-escrow/agent/internal/config"
)

const (
	testKey     = "0xabc123"
	testAPIKey  = "sk-ant-test"
	testAddress = "0x1234567890123456789012345678901234567890"
)

// setEnv installs the given variables for the duration of the test, clearing
// any the caller did not name.
func setEnv(t *testing.T, vars map[string]string) {
	t.Helper()
	for _, name := range []string{
		config.EnvPrivateKey,
		config.EnvAnthropicAPIKey,
		config.EnvRPCURL,
		config.EnvEscrowAddress,
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
