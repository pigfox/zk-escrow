// Package ai wraps the Anthropic Messages API and turns the model's reply
// into a Decision the executor can broadcast.
//
// The Client interface is the seam every test uses: the real implementation
// speaks HTTP, and fakes return canned text or errors without touching the
// network.
package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/escrow"
)

// Sentinel errors. Callers match these with errors.Is.
var (
	// ErrRequestFailed means the HTTP round trip did not complete.
	ErrRequestFailed = errors.New("ai: anthropic request failed")
	// ErrUnexpectedStatus means the API answered with a non-200 status.
	ErrUnexpectedStatus = errors.New("ai: anthropic returned unexpected status")
	// ErrReadBody means the response body could not be read.
	ErrReadBody = errors.New("ai: reading anthropic response body")
	// ErrDecodeResponse means the API envelope was not valid JSON.
	ErrDecodeResponse = errors.New("ai: decoding anthropic response")
	// ErrNoTextContent means the envelope carried no text content block.
	ErrNoTextContent = errors.New("ai: anthropic response had no text content")
	// ErrBuildRequest means the HTTP request could not be constructed.
	ErrBuildRequest = errors.New("ai: building anthropic request")
	// ErrEncodeRequest means the request body could not be marshalled.
	ErrEncodeRequest = errors.New("ai: encoding anthropic request")

	// ErrEmptyDecision means the model returned nothing to parse.
	ErrEmptyDecision = errors.New("ai: model returned an empty decision")
	// ErrMalformedDecision means the model's reply was not the agreed JSON.
	ErrMalformedDecision = errors.New("ai: model returned malformed decision JSON")
	// ErrUnknownRuling means the ruling string was neither BuyerWins nor
	// SellerWins.
	ErrUnknownRuling = errors.New("ai: model returned an unknown ruling")
	// ErrEmptyRationale means the rationale was blank, which resolveDispute
	// would reject on chain.
	ErrEmptyRationale = errors.New("ai: model returned an empty rationale")
)

// Client is the arbiter's view of the language model.
type Client interface {
	// Complete sends the prompts and returns the model's raw text reply.
	Complete(ctx context.Context, systemPrompt, userPrompt string) (string, error)
}

// Doer is the subset of *http.Client the HTTPClient needs, so tests can swap
// in a transport that fails or returns an unreadable body.
type Doer interface {
	Do(req *http.Request) (*http.Response, error)
}

// Marshaller encodes the request body. It is a field rather than a direct call
// to json.Marshal so the encoding failure path is reachable from a test.
type Marshaller func(v any) ([]byte, error)

// HTTPClient is the real Anthropic Messages API client.
type HTTPClient struct {
	// BaseURL is the Messages endpoint.
	BaseURL string
	// APIKey authenticates the request. Never logged.
	APIKey string
	// Model is the model id to invoke.
	Model string
	// MaxTokens bounds the reply.
	MaxTokens int
	// HTTP performs the round trip.
	HTTP Doer
	// Marshal encodes the request body.
	Marshal Marshaller
}

// NewHTTPClient builds an HTTPClient wired to the real endpoint and a timeout
// bounded http.Client.
func NewHTTPClient(apiKey string, doer Doer) *HTTPClient {
	return &HTTPClient{
		BaseURL:   config.AnthropicBaseURL,
		APIKey:    apiKey,
		Model:     config.AnthropicModel,
		MaxTokens: config.AnthropicMaxTokens,
		HTTP:      doer,
		Marshal:   json.Marshal,
	}
}

// message is one entry in the Messages API `messages` array.
type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// request is the Messages API request body.
type request struct {
	Model     string    `json:"model"`
	MaxTokens int       `json:"max_tokens"`
	System    string    `json:"system"`
	Messages  []message `json:"messages"`
}

// contentBlock is one entry in the response `content` array.
type contentBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// response is the subset of the Messages API response the agent reads.
type response struct {
	Content []contentBlock `json:"content"`
}

// Complete implements Client against the real API.
func (c *HTTPClient) Complete(ctx context.Context, systemPrompt, userPrompt string) (string, error) {
	body, err := c.Marshal(request{
		Model:     c.Model,
		MaxTokens: c.MaxTokens,
		System:    systemPrompt,
		Messages:  []message{{Role: config.RoleUser, Content: userPrompt}},
	})
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrEncodeRequest, err)
	}

	req, err := http.NewRequestWithContext(
		ctx, config.HTTPMethodPost, c.BaseURL, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrBuildRequest, err)
	}
	req.Header.Set(config.HeaderAPIKey, c.APIKey)
	req.Header.Set(config.HeaderAnthropicVersion, config.AnthropicVersion)
	req.Header.Set(config.HeaderContentType, config.ContentTypeJSON)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrRequestFailed, err)
	}
	defer func() { _ = resp.Body.Close() }()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrReadBody, err)
	}

	if resp.StatusCode != config.HTTPStatusOK {
		// Include the API's own message. The status alone is close to useless
		// for diagnosis: a 400 covers a malformed request, an unknown model
		// and an exhausted credit balance alike, and only the body says which.
		// The body carries the error description, never the request or the key.
		return "", fmt.Errorf("%w: %d: %s",
			ErrUnexpectedStatus, resp.StatusCode, truncate(string(raw), config.ErrorBodyMaxLen))
	}

	var decoded response
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return "", fmt.Errorf("%w: %w", ErrDecodeResponse, err)
	}

	for _, block := range decoded.Content {
		if block.Type == config.ContentTypeText {
			return block.Text, nil
		}
	}
	return "", ErrNoTextContent
}

// decisionPayload is the JSON contract the system prompt demands.
type decisionPayload struct {
	Ruling    string `json:"ruling"`
	Rationale string `json:"rationale"`
}

// ParseDecision turns the model's raw reply into a Decision, rejecting
// anything that resolveDispute would refuse on chain.
func ParseDecision(raw string) (escrow.Decision, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return escrow.Decision{}, ErrEmptyDecision
	}

	var payload decisionPayload
	if err := json.Unmarshal([]byte(trimmed), &payload); err != nil {
		return escrow.Decision{}, fmt.Errorf("%w: %w", ErrMalformedDecision, err)
	}

	var ruling uint8
	switch payload.Ruling {
	case config.RulingBuyerWinsString:
		ruling = config.RulingBuyerWins
	case config.RulingSellerWinsString:
		ruling = config.RulingSellerWins
	default:
		return escrow.Decision{}, fmt.Errorf("%w: %q", ErrUnknownRuling, payload.Ruling)
	}

	rationale := strings.TrimSpace(payload.Rationale)
	if rationale == "" {
		return escrow.Decision{}, ErrEmptyRationale
	}

	return escrow.Decision{
		Ruling:     ruling,
		RulingName: payload.Ruling,
		Rationale:  rationale,
	}, nil
}

// BuildPrompt renders a dispute's evidence bundle into the user prompt.
func BuildPrompt(dispute escrow.Dispute) string {
	var b strings.Builder
	// Fprintf to the builder rather than WriteString(Sprintf(...)): a
	// strings.Builder never returns an error, so the discarded returns are safe
	// and it avoids an intermediate allocation per segment.
	fmt.Fprintf(&b, config.PromptHeaderFormat, dispute.EscrowID.String())
	for i, submission := range dispute.Submissions {
		fmt.Fprintf(&b, config.PromptEvidenceFormat,
			i+1, submission.RaisedBy.Hex(), submission.Evidence)
	}
	b.WriteString(config.PromptFooter)
	return b.String()
}

// truncate bounds an error body so a runaway response cannot flood the log,
// while keeping enough of it to be diagnostic.
func truncate(s string, limit int) string {
	s = strings.TrimSpace(s)
	if len(s) <= limit {
		return s
	}
	return s[:limit] + config.TruncationSuffix
}
