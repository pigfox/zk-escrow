// Package config holds every literal the agent uses and loads operator
// configuration from the process environment.
//
// No other package in this module may declare a string or numeric literal that
// represents configuration, an ABI fragment, a log message, or a protocol
// constant. Everything lives here so the whole surface can be audited in one
// file.
package config

import (
	"log"
	"time"
)

// Environment variable names. The operator is expected to `source ../.env`
// before running the agent, so these are read from the process environment
// only -- the agent never opens a dotenv file itself.
const (
	// EnvPrivateKey is the arbiter's private key. Required.
	EnvPrivateKey = "PRIVATE_KEY"
	// EnvAnthropicAPIKey is the Anthropic API key. Required when the selected
	// provider is ProviderAnthropic.
	EnvAnthropicAPIKey = "ANTHROPIC_API_KEY"
	// EnvOpenAIAPIKey is the OpenAI API key. Required when the selected
	// provider is ProviderOpenAI.
	EnvOpenAIAPIKey = "OPENAI_API_KEY"
	// EnvAIProvider selects which model backend arbitrates. Optional;
	// defaults to DefaultAIProvider.
	EnvAIProvider = "AI_PROVIDER"
	// EnvRPCURL optionally overrides DefaultRPCURL.
	EnvRPCURL = "RPC_URL"
	// EnvEscrowAddress optionally overrides DefaultEscrowAddress.
	EnvEscrowAddress = "ESCROW_ADDRESS"
)

// Chain configuration. Base Sepolia only -- ChainID is compared against
// nothing else, and there is deliberately no way to point this agent at
// mainnet.
const (
	// DefaultRPCURL is the public Base Sepolia JSON-RPC endpoint.
	DefaultRPCURL = "https://sepolia.base.org"
	// ChainID is the Base Sepolia chain id. Never a mainnet id.
	ChainID int64 = 84532
	// ChainIDDecimal is ChainID rendered for the cast command line.
	ChainIDDecimal = "84532"
	// DefaultEscrowAddress is the deployed EscrowUpgradeable proxy. Override
	// with ESCROW_ADDRESS.
	DefaultEscrowAddress = "0x0000000000000000000000000000000000000000"
)

// Polling behaviour. The agent uses eth_getLogs on a ticker; it never opens a
// websocket subscription.
const (
	// PollInterval is how often the agent scans for new logs.
	PollInterval = 15 * time.Second
	// BlockRangeChunkSize bounds a single eth_getLogs range so public RPC
	// providers do not reject the request.
	BlockRangeChunkSize uint64 = 500
	// StartBlockLookback is how many blocks behind head the agent begins
	// scanning on a cold start.
	StartBlockLookback uint64 = 5000
	// BlockConfirmations is how far behind head the agent stops scanning, so
	// it never rules on a reorged log.
	BlockConfirmations uint64 = 2
)

// Contract ABI surface. These strings are parsed by abi.JSON at init time in
// the chain package; a typo fails fast and loudly.
const (
	// EscrowABIJSON covers only the fragments the agent needs: the
	// DisputeRaised event it reads and the getState view it calls.
	EscrowABIJSON = `[
		{
			"type": "event",
			"name": "DisputeRaised",
			"inputs": [
				{"name": "escrowId", "type": "uint256", "indexed": true},
				{"name": "raisedBy", "type": "address", "indexed": true},
				{"name": "evidence", "type": "string", "indexed": false}
			],
			"anonymous": false
		},
		{
			"type": "function",
			"name": "getState",
			"stateMutability": "view",
			"inputs": [{"name": "escrowId", "type": "uint256"}],
			"outputs": [{"name": "", "type": "uint8"}]
		}
	]`
	// EventDisputeRaised is the ABI name of the event the agent watches.
	EventDisputeRaised = "DisputeRaised"
	// MethodGetState is the ABI name of the state view the agent calls.
	MethodGetState = "getState"
	// ResolveDisputeSignature is the cast-style signature of the write call.
	ResolveDisputeSignature = "resolveDispute(uint256,uint8,string)"
)

// Escrow lifecycle states, mirroring the Solidity `enum State`.
const (
	StateNone     uint8 = 0
	StateCreated  uint8 = 1
	StateFunded   uint8 = 2
	StateReleased uint8 = 3
	StateRefunded uint8 = 4
	StateDisputed uint8 = 5
	StateResolved uint8 = 6
)

// Ruling values, mirroring the Solidity `enum Ruling`.
const (
	// RulingBuyerWins is Ruling.BuyerWins == 0.
	RulingBuyerWins uint8 = 0
	// RulingSellerWins is Ruling.SellerWins == 1.
	RulingSellerWins uint8 = 1
)

// Ruling strings as they appear in the model's JSON response.
const (
	RulingBuyerWinsString  = "BuyerWins"
	RulingSellerWinsString = "SellerWins"
)

// Model providers. The arbiter's reasoning backend is pluggable: the same
// structured prompt and the same {ruling, rationale} JSON contract are used
// whichever one is selected, so a ruling does not depend on the vendor.
const (
	// ProviderAnthropic selects the Anthropic Messages API.
	ProviderAnthropic = "anthropic"
	// ProviderOpenAI selects the OpenAI Chat Completions API.
	ProviderOpenAI = "openai"
	// DefaultAIProvider is used when AI_PROVIDER is unset. Claude is the
	// documented default.
	DefaultAIProvider = ProviderAnthropic
)

// OpenAI API surface. Mirrors the Anthropic block: same prompt, same JSON
// contract, different envelope.
const (
	// OpenAIBaseURL is the Chat Completions endpoint.
	OpenAIBaseURL = "https://api.openai.com/v1/chat/completions"
	// OpenAIModel is the model the arbiter reasons with when the OpenAI
	// provider is selected.
	OpenAIModel = "gpt-5.4-nano"
	// OpenAIMaxTokens bounds the model's reply.
	OpenAIMaxTokens = 1024
	// OpenAITimeout bounds a single API round trip.
	OpenAITimeout = 60 * time.Second

	// HeaderAuthorization carries the bearer token.
	HeaderAuthorization = "Authorization"
	// BearerPrefix prefixes the OpenAI API key in HeaderAuthorization.
	BearerPrefix = "Bearer "

	// RoleSystem is the Chat Completions role carrying the system prompt.
	// Anthropic takes the system prompt as a top-level field instead.
	RoleSystem = "system"
)

// Anthropic API surface.
const (
	// AnthropicBaseURL is the Messages endpoint.
	AnthropicBaseURL = "https://api.anthropic.com/v1/messages"
	// AnthropicModel is the model the arbiter reasons with.
	AnthropicModel = "claude-sonnet-5"
	// AnthropicVersion is the value of the anthropic-version header.
	AnthropicVersion = "2023-06-01"
	// AnthropicMaxTokens bounds the model's reply.
	AnthropicMaxTokens = 1024
	// AnthropicTimeout bounds a single API round trip.
	AnthropicTimeout = 60 * time.Second

	// HeaderAPIKey carries the Anthropic API key.
	HeaderAPIKey = "x-api-key"
	// HeaderAnthropicVersion carries AnthropicVersion.
	HeaderAnthropicVersion = "anthropic-version"
	// HeaderContentType carries ContentTypeJSON.
	HeaderContentType = "content-type"
	// ContentTypeJSON is the request body media type.
	ContentTypeJSON = "application/json"

	// HTTPMethodPost is the verb used for the Messages endpoint.
	HTTPMethodPost = "POST"
	// HTTPStatusOK is the only status the agent accepts.
	HTTPStatusOK = 200
	// ErrorBodyMaxLen bounds how much of a non-200 response body is quoted
	// back in the error, so a runaway response cannot flood the log.
	ErrorBodyMaxLen = 512
	// TruncationSuffix marks a body clipped at ErrorBodyMaxLen.
	TruncationSuffix = "... (truncated)"

	// RoleUser is the Messages API role for the arbiter's prompt.
	RoleUser = "user"
	// ContentTypeText is the response content block type carrying the answer.
	ContentTypeText = "text"
)

// Prompt text. The system prompt pins the output contract; the user prompt is
// assembled from the evidence bundle.
const (
	// SystemPrompt constrains the model to a single JSON object.
	SystemPrompt = "You are an impartial arbiter settling a two-party escrow " +
		"dispute on a blockchain. You will be given every piece of evidence " +
		"submitted by both parties. Weigh it and pick exactly one winner.\n\n" +
		"Respond with a single JSON object and nothing else. No prose, no " +
		"markdown, no code fences. The object must have exactly these keys:\n" +
		`  "ruling":    either "BuyerWins" or "SellerWins"` + "\n" +
		`  "rationale": a concise explanation of why, addressed to both parties` +
		"\n\nThe rationale must be non-empty, because it is written to the " +
		"blockchain verbatim and is the only record the parties receive."

	// PromptHeaderFormat introduces the escrow under consideration.
	PromptHeaderFormat = "Escrow #%s is disputed. The following evidence was submitted:\n\n"
	// PromptEvidenceFormat renders one submission.
	PromptEvidenceFormat = "Evidence %d, submitted by %s:\n%s\n\n"
	// PromptFooter closes the bundle.
	PromptFooter = "Decide which party wins and explain why."
)

// cast invocation.
const (
	// CastBinary is the foundry binary the agent shells out to.
	CastBinary = "cast"
	// CastSend is the cast subcommand that broadcasts a transaction.
	CastSend = "send"
	// CastFlagRPCURL selects the endpoint.
	CastFlagRPCURL = "--rpc-url"
	// CastFlagChainID pins the chain.
	CastFlagChainID = "--chain-id"
	// CastFlagPrivateKey supplies the signing key.
	CastFlagPrivateKey = "--private-key"
	// RedactedPlaceholder replaces every secret in logged output. The real
	// value is only ever present in the exec argv.
	RedactedPlaceholder = "***REDACTED***"
)

// Log message formats. Centralised so a review can confirm no format string
// carries a secret.
const (
	LogStarting            = "arbiter starting: rpc=%s escrow=%s chainID=%d model=%s"
	LogScanning            = "scanning blocks %d..%d"
	LogDisputeFound        = "escrow %s: %d evidence submission(s) gathered"
	LogSkippingNotDisputed = "escrow %s: state is %d, not Disputed(%d) -- skipping"
	LogRuling              = "escrow %s: ruling=%s (%d)"
	LogExecuting           = "executing: %s"
	LogExecuted            = "escrow %s: resolveDispute broadcast\n%s"
	LogPollError           = "poll error: %v"
	LogEscrowError         = "escrow %s: %v"
	LogShutdown            = "shutdown requested, arbiter stopping"
)

// Logger configuration.
const (
	// LogPrefix prefixes every line the agent writes.
	LogPrefix = "arbiter: "
	// LogFlags selects date and time on every line.
	LogFlags = log.LstdFlags
)

// Process exit codes.
const (
	// ExitOK means a clean shutdown.
	ExitOK = 0
	// ExitConfigError means the environment was missing or invalid.
	ExitConfigError = 1
	// ExitDialError means the RPC endpoint could not be opened.
	ExitDialError = 2
	// ExitChainError means the escrow ABI could not be bound.
	ExitChainError = 3
)

// Numeric formatting bases.
const (
	// DecimalBase is the base escrow ids and rulings are rendered in.
	DecimalBase = 10
	// UintBitSize is the bit size used when parsing ruling enum values.
	UintBitSize = 8
)
