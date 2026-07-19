package ai_test

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pigfox/zk-escrow/agent/internal/ai"
	"github.com/pigfox/zk-escrow/agent/internal/config"
)

// TestNewOpenAIClientDefaults pins the wiring a caller gets for free.
func TestNewOpenAIClientDefaults(t *testing.T) {
	client := ai.NewOpenAIClient("secret-key", http.DefaultClient)

	if client.BaseURL != config.OpenAIBaseURL {
		t.Errorf("BaseURL = %q, want %q", client.BaseURL, config.OpenAIBaseURL)
	}
	if client.Model != config.OpenAIModel {
		t.Errorf("Model = %q, want %q", client.Model, config.OpenAIModel)
	}
	if client.MaxTokens != config.OpenAIMaxTokens {
		t.Errorf("MaxTokens = %d, want %d", client.MaxTokens, config.OpenAIMaxTokens)
	}
	if client.APIKey != "secret-key" {
		t.Errorf("APIKey was not stored")
	}
	if client.Marshal == nil || client.HTTP == nil {
		t.Error("Marshal and HTTP must be wired")
	}
}

// TestOpenAICompleteSuccess drives a real round trip against a local server and
// asserts the request shape the API expects — bearer auth, the system prompt as
// a role:system message, and the model id.
func TestOpenAICompleteSuccess(t *testing.T) {
	const apiKey = "sk-test-key"
	var gotAuth, gotContentType, gotBody string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get(config.HeaderAuthorization)
		gotContentType = r.Header.Get(config.HeaderContentType)
		raw, _ := io.ReadAll(r.Body)
		gotBody = string(raw)

		w.Header().Set(config.HeaderContentType, config.ContentTypeJSON)
		_, _ = io.WriteString(w,
			`{"choices":[{"message":{"content":"{\"ruling\":\"BuyerWins\",\"rationale\":\"No proof of delivery.\"}"}}]}`)
	}))
	defer server.Close()

	client := ai.NewOpenAIClient(apiKey, server.Client())
	client.BaseURL = server.URL

	got, err := client.Complete(t.Context(), "you are an arbiter", "escrow 7 evidence")
	if err != nil {
		t.Fatalf("Complete() unexpected error: %v", err)
	}

	if !strings.Contains(got, config.RulingBuyerWinsString) {
		t.Errorf("reply did not carry the ruling: %q", got)
	}
	if gotAuth != config.BearerPrefix+apiKey {
		t.Error("Authorization header was not a bearer token carrying the key")
	}
	if gotContentType != config.ContentTypeJSON {
		t.Errorf("content-type = %q, want %q", gotContentType, config.ContentTypeJSON)
	}
	for _, want := range []string{
		config.OpenAIModel,
		`"role":"` + config.RoleSystem + `"`,
		`"role":"` + config.RoleUser + `"`,
		"you are an arbiter",
		"escrow 7 evidence",
	} {
		if !strings.Contains(gotBody, want) {
			t.Errorf("request body missing %q\nbody: %s", want, gotBody)
		}
	}
}

// TestOpenAICompleteParsesIntoADecision closes the loop: the client's raw reply
// must survive ParseDecision, which is the contract the arbiter depends on and
// the whole point of the two backends being interchangeable.
func TestOpenAICompleteParsesIntoADecision(t *testing.T) {
	client := ai.NewOpenAIClient("key", http.DefaultClient)
	client.HTTP = bodyTransport{
		status: config.HTTPStatusOK,
		body: strings.NewReader(
			`{"choices":[{"message":{"content":"{\"ruling\":\"SellerWins\",\"rationale\":\"Delivery was signed for.\"}"}}]}`),
	}

	raw, err := client.Complete(t.Context(), "system", "user")
	if err != nil {
		t.Fatalf("Complete() unexpected error: %v", err)
	}

	decision, err := ai.ParseDecision(raw)
	if err != nil {
		t.Fatalf("ParseDecision() unexpected error: %v", err)
	}
	if decision.Ruling != config.RulingSellerWins {
		t.Errorf("Ruling = %d, want %d", decision.Ruling, config.RulingSellerWins)
	}
	if decision.Rationale != "Delivery was signed for." {
		t.Errorf("Rationale = %q", decision.Rationale)
	}
}

// TestOpenAICompleteMalformedRulingIsRejected covers a reply that arrives
// cleanly over HTTP but is not the agreed JSON. The transport succeeded, so
// this has to be caught downstream rather than by a status check.
func TestOpenAICompleteMalformedRulingIsRejected(t *testing.T) {
	tests := []struct {
		name    string
		content string
		wantErr error
	}{
		{
			name:    "prose instead of JSON",
			content: "I think the buyer should win.",
			wantErr: ai.ErrMalformedDecision,
		},
		{
			name:    "unknown ruling value",
			content: `{\"ruling\":\"ArbiterWins\",\"rationale\":\"mine now\"}`,
			wantErr: ai.ErrUnknownRuling,
		},
		{
			name:    "blank rationale",
			content: `{\"ruling\":\"BuyerWins\",\"rationale\":\"   \"}`,
			wantErr: ai.ErrEmptyRationale,
		},
		{
			name:    "empty reply",
			content: "   ",
			wantErr: ai.ErrEmptyDecision,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := ai.NewOpenAIClient("key", http.DefaultClient)
			client.HTTP = bodyTransport{
				status: config.HTTPStatusOK,
				body:   strings.NewReader(`{"choices":[{"message":{"content":"` + tt.content + `"}}]}`),
			}

			raw, err := client.Complete(t.Context(), "system", "user")
			if err != nil {
				t.Fatalf("Complete() unexpected transport error: %v", err)
			}
			if _, err := ai.ParseDecision(raw); !errors.Is(err, tt.wantErr) {
				t.Errorf("ParseDecision() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestOpenAICompleteFailures is the table of transport and envelope failures,
// mirroring the Anthropic client's suite.
func TestOpenAICompleteFailures(t *testing.T) {
	readErr := errors.New("connection reset")

	tests := []struct {
		name    string
		mutate  func(*ai.OpenAIClient)
		wantErr error
	}{
		{
			name: "request body cannot be encoded",
			mutate: func(c *ai.OpenAIClient) {
				c.Marshal = func(any) ([]byte, error) { return nil, errors.New("nope") }
			},
			wantErr: ai.ErrEncodeRequest,
		},
		{
			name: "endpoint is not a usable URL",
			mutate: func(c *ai.OpenAIClient) {
				c.BaseURL = "://not a url"
			},
			wantErr: ai.ErrBuildRequest,
		},
		{
			name: "round trip fails",
			mutate: func(c *ai.OpenAIClient) {
				c.HTTP = errTransport{err: errors.New("dial tcp: refused")}
			},
			wantErr: ai.ErrRequestFailed,
		},
		{
			name: "body cannot be read",
			mutate: func(c *ai.OpenAIClient) {
				c.HTTP = bodyTransport{status: config.HTTPStatusOK, body: errReader{err: readErr}}
			},
			wantErr: ai.ErrReadBody,
		},
		{
			name: "non-200 status",
			mutate: func(c *ai.OpenAIClient) {
				c.HTTP = bodyTransport{
					status: 401,
					body:   strings.NewReader(`{"error":{"message":"Incorrect API key provided"}}`),
				}
			},
			wantErr: ai.ErrUnexpectedStatus,
		},
		{
			name: "success status with a non-JSON body",
			mutate: func(c *ai.OpenAIClient) {
				c.HTTP = bodyTransport{
					status: config.HTTPStatusOK,
					body:   strings.NewReader("<html>gateway error</html>"),
				}
			},
			wantErr: ai.ErrDecodeResponse,
		},
		{
			name: "response carries no choices",
			mutate: func(c *ai.OpenAIClient) {
				c.HTTP = bodyTransport{
					status: config.HTTPStatusOK,
					body:   strings.NewReader(`{"choices":[]}`),
				}
			},
			wantErr: ai.ErrNoTextContent,
		},
		{
			name: "choice carries empty content",
			mutate: func(c *ai.OpenAIClient) {
				c.HTTP = bodyTransport{
					status: config.HTTPStatusOK,
					body:   strings.NewReader(`{"choices":[{"message":{"content":""}}]}`),
				}
			},
			wantErr: ai.ErrNoTextContent,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := ai.NewOpenAIClient("key", http.DefaultClient)
			client.BaseURL = "http://127.0.0.1:1"
			tt.mutate(client)

			if _, err := client.Complete(t.Context(), "system", "user"); !errors.Is(err, tt.wantErr) {
				t.Errorf("Complete() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestOpenAICompleteSurfacesTheAPIErrorBody pins the same diagnostic the
// Anthropic client gained: a bare status cannot distinguish a bad model id from
// an exhausted quota, so the body has to travel with the error.
func TestOpenAICompleteSurfacesTheAPIErrorBody(t *testing.T) {
	const apiMessage = "The model `gpt-nonexistent` does not exist"

	client := ai.NewOpenAIClient("key", http.DefaultClient)
	client.HTTP = bodyTransport{
		status: 404,
		body:   strings.NewReader(`{"error":{"message":"` + apiMessage + `"}}`),
	}

	_, err := client.Complete(t.Context(), "system", "user")
	if !errors.Is(err, ai.ErrUnexpectedStatus) {
		t.Fatalf("Complete() error = %v, want ErrUnexpectedStatus", err)
	}
	if !strings.Contains(err.Error(), apiMessage) {
		t.Errorf("error dropped the API's own message: %v", err)
	}
	if !strings.Contains(err.Error(), "404") {
		t.Errorf("error dropped the status code: %v", err)
	}
}

// TestOpenAICompleteTimeout covers the deadline path: a server that never
// answers must surface as a request failure rather than hanging the poll loop.
func TestOpenAICompleteTimeout(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		<-release
	}))
	defer func() {
		close(release)
		server.Close()
	}()

	client := ai.NewOpenAIClient("key", &http.Client{Timeout: 50 * time.Millisecond})
	client.BaseURL = server.URL

	_, err := client.Complete(t.Context(), "system", "user")
	if !errors.Is(err, ai.ErrRequestFailed) {
		t.Fatalf("Complete() error = %v, want ErrRequestFailed", err)
	}
}

// TestOpenAICompleteHonoursContextCancellation proves the client stops when the
// arbiter shuts down mid-flight, rather than holding the process open.
func TestOpenAICompleteHonoursContextCancellation(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		<-release
	}))
	defer func() {
		close(release)
		server.Close()
	}()

	ctx, cancel := context.WithCancel(t.Context())
	client := ai.NewOpenAIClient("key", server.Client())
	client.BaseURL = server.URL

	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()

	_, err := client.Complete(ctx, "system", "user")
	if !errors.Is(err, ai.ErrRequestFailed) {
		t.Fatalf("Complete() error = %v, want ErrRequestFailed", err)
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("error did not wrap context.Canceled: %v", err)
	}
}
