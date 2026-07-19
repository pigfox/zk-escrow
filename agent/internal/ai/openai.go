package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/pigfox/zk-escrow/agent/internal/config"
)

// OpenAIClient is a Client backed by the OpenAI Chat Completions API.
//
// It is interchangeable with HTTPClient: same prompts in, same raw text out,
// and the caller still runs the reply through ParseDecision. Only the request
// envelope and the auth header differ — OpenAI carries the system prompt as a
// message with role "system", where Anthropic takes it as a top-level field.
type OpenAIClient struct {
	// BaseURL is the Chat Completions endpoint.
	BaseURL string
	// APIKey authenticates the request. Never logged.
	APIKey string
	// Model is the model id to invoke.
	Model string
	// MaxTokens bounds the reply.
	MaxTokens int
	// HTTP performs the round trip.
	HTTP Doer
	// Marshal encodes the request body. A field, not a direct json.Marshal
	// call, so the encoding failure path is reachable from a test.
	Marshal Marshaller
}

// NewOpenAIClient builds an OpenAIClient wired to the real endpoint.
func NewOpenAIClient(apiKey string, doer Doer) *OpenAIClient {
	return &OpenAIClient{
		BaseURL:   config.OpenAIBaseURL,
		APIKey:    apiKey,
		Model:     config.OpenAIModel,
		MaxTokens: config.OpenAIMaxTokens,
		HTTP:      doer,
		Marshal:   json.Marshal,
	}
}

// openAIRequest is the Chat Completions request body.
type openAIRequest struct {
	Model     string    `json:"model"`
	MaxTokens int       `json:"max_completion_tokens"`
	Messages  []message `json:"messages"`
}

// openAIChoice is one entry in the response `choices` array.
type openAIChoice struct {
	Message struct {
		Content string `json:"content"`
	} `json:"message"`
}

// openAIResponse is the subset of the Chat Completions response the agent
// reads.
type openAIResponse struct {
	Choices []openAIChoice `json:"choices"`
}

// Complete implements Client against the OpenAI Chat Completions API.
func (c *OpenAIClient) Complete(ctx context.Context, systemPrompt, userPrompt string) (string, error) {
	body, err := c.Marshal(openAIRequest{
		Model:     c.Model,
		MaxTokens: c.MaxTokens,
		Messages: []message{
			{Role: config.RoleSystem, Content: systemPrompt},
			{Role: config.RoleUser, Content: userPrompt},
		},
	})
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrEncodeRequest, err)
	}

	req, err := http.NewRequestWithContext(
		ctx, config.HTTPMethodPost, c.BaseURL, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrBuildRequest, err)
	}
	req.Header.Set(config.HeaderAuthorization, config.BearerPrefix+c.APIKey)
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
		// Same reasoning as the Anthropic client: the status alone cannot
		// distinguish a bad model id from an exhausted quota, and the body
		// already read here says which. It carries the error description,
		// never the request or the key.
		return "", fmt.Errorf("%w: %d: %s",
			ErrUnexpectedStatus, resp.StatusCode, truncate(string(raw), config.ErrorBodyMaxLen))
	}

	var decoded openAIResponse
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return "", fmt.Errorf("%w: %w", ErrDecodeResponse, err)
	}

	for _, choice := range decoded.Choices {
		if choice.Message.Content != "" {
			return choice.Message.Content, nil
		}
	}
	return "", ErrNoTextContent
}
