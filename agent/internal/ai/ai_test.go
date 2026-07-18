package ai_test

import (
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/pigfox/zk-escrow/agent/internal/ai"
	"github.com/pigfox/zk-escrow/agent/internal/config"
	"github.com/pigfox/zk-escrow/agent/internal/escrow"
)

// errTransport is a Doer whose round trip always fails.
type errTransport struct{ err error }

func (e errTransport) Do(*http.Request) (*http.Response, error) { return nil, e.err }

// errReader fails on the first read, exercising the unreadable-body branch.
type errReader struct{ err error }

func (e errReader) Read([]byte) (int, error) { return 0, e.err }

// bodyTransport returns a fixed response whose body is the supplied reader.
type bodyTransport struct {
	status int
	body   io.Reader
}

func (b bodyTransport) Do(*http.Request) (*http.Response, error) {
	return &http.Response{
		StatusCode: b.status,
		Body:       io.NopCloser(b.body),
	}, nil
}

// TestParseDecision is the table-driven ruling parser suite.
func TestParseDecision(t *testing.T) {
	tests := []struct {
		name       string
		raw        string
		wantErr    error
		wantRuling uint8
		wantName   string
		wantReason string
	}{
		{
			name:       "buyer wins",
			raw:        `{"ruling":"BuyerWins","rationale":"Seller never shipped."}`,
			wantRuling: config.RulingBuyerWins,
			wantName:   config.RulingBuyerWinsString,
			wantReason: "Seller never shipped.",
		},
		{
			name:       "seller wins",
			raw:        `{"ruling":"SellerWins","rationale":"Tracking shows delivery."}`,
			wantRuling: config.RulingSellerWins,
			wantName:   config.RulingSellerWinsString,
			wantReason: "Tracking shows delivery.",
		},
		{
			name:       "surrounding whitespace is tolerated",
			raw:        "\n\t  {\"ruling\":\"BuyerWins\",\"rationale\":\"  Refund owed.  \"}  \n",
			wantRuling: config.RulingBuyerWins,
			wantName:   config.RulingBuyerWinsString,
			wantReason: "Refund owed.",
		},
		{
			name:       "extra keys are ignored",
			raw:        `{"ruling":"SellerWins","rationale":"Delivered.","confidence":0.9}`,
			wantRuling: config.RulingSellerWins,
			wantName:   config.RulingSellerWinsString,
			wantReason: "Delivered.",
		},
		{
			name:    "empty reply",
			raw:     "   \n\t ",
			wantErr: ai.ErrEmptyDecision,
		},
		{
			name:    "malformed json",
			raw:     `{"ruling": "BuyerWins",`,
			wantErr: ai.ErrMalformedDecision,
		},
		{
			name:    "prose instead of json",
			raw:     "The buyer should win because the seller never shipped.",
			wantErr: ai.ErrMalformedDecision,
		},
		{
			name:    "unknown ruling string",
			raw:     `{"ruling":"ArbiterWins","rationale":"Nope."}`,
			wantErr: ai.ErrUnknownRuling,
		},
		{
			name:    "ruling casing must match exactly",
			raw:     `{"ruling":"buyerwins","rationale":"Nope."}`,
			wantErr: ai.ErrUnknownRuling,
		},
		{
			name:    "missing ruling key",
			raw:     `{"rationale":"Nope."}`,
			wantErr: ai.ErrUnknownRuling,
		},
		{
			name:    "blank rationale is rejected",
			raw:     `{"ruling":"BuyerWins","rationale":"   "}`,
			wantErr: ai.ErrEmptyRationale,
		},
		{
			name:    "missing rationale key",
			raw:     `{"ruling":"BuyerWins"}`,
			wantErr: ai.ErrEmptyRationale,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			decision, err := ai.ParseDecision(tt.raw)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("ParseDecision() error = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseDecision() unexpected error: %v", err)
			}
			if decision.Ruling != tt.wantRuling {
				t.Errorf("Ruling = %d, want %d", decision.Ruling, tt.wantRuling)
			}
			if decision.RulingName != tt.wantName {
				t.Errorf("RulingName = %q, want %q", decision.RulingName, tt.wantName)
			}
			if decision.Rationale != tt.wantReason {
				t.Errorf("Rationale = %q, want %q", decision.Rationale, tt.wantReason)
			}
		})
	}
}

func TestBuildPrompt(t *testing.T) {
	buyer := common.HexToAddress("0x1111111111111111111111111111111111111111")
	seller := common.HexToAddress("0x2222222222222222222222222222222222222222")

	prompt := ai.BuildPrompt(escrow.Dispute{
		EscrowID: big.NewInt(7),
		Submissions: []escrow.Submission{
			{RaisedBy: buyer, Evidence: "Nothing arrived."},
			{RaisedBy: seller, Evidence: "Tracking 123 shows delivered."},
		},
	})

	for _, want := range []string{
		"Escrow #7",
		buyer.Hex(),
		seller.Hex(),
		"Nothing arrived.",
		"Tracking 123 shows delivered.",
		config.PromptFooter,
		"Evidence 1",
		"Evidence 2",
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt missing %q\ngot:\n%s", want, prompt)
		}
	}
}

func TestBuildPromptWithNoSubmissions(t *testing.T) {
	prompt := ai.BuildPrompt(escrow.Dispute{EscrowID: big.NewInt(0)})
	if !strings.Contains(prompt, config.PromptFooter) {
		t.Errorf("prompt missing footer: %s", prompt)
	}
}

func TestNewHTTPClientDefaults(t *testing.T) {
	client := ai.NewHTTPClient("secret-key", http.DefaultClient)
	if client.BaseURL != config.AnthropicBaseURL {
		t.Errorf("BaseURL = %q, want %q", client.BaseURL, config.AnthropicBaseURL)
	}
	if client.Model != config.AnthropicModel {
		t.Errorf("Model = %q, want %q", client.Model, config.AnthropicModel)
	}
	if client.MaxTokens != config.AnthropicMaxTokens {
		t.Errorf("MaxTokens = %d, want %d", client.MaxTokens, config.AnthropicMaxTokens)
	}
	if client.Marshal == nil {
		t.Error("Marshal must default to json.Marshal")
	}
}

// TestCompleteSuccess exercises the happy path against a real HTTP server and
// asserts the request shape the Messages API requires.
func TestCompleteSuccess(t *testing.T) {
	const apiKey = "sk-ant-secret"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != config.HTTPMethodPost {
			t.Errorf("method = %s, want %s", r.Method, config.HTTPMethodPost)
		}
		if got := r.Header.Get(config.HeaderAPIKey); got != apiKey {
			t.Errorf("%s = %q, want %q", config.HeaderAPIKey, got, apiKey)
		}
		if got := r.Header.Get(config.HeaderAnthropicVersion); got != config.AnthropicVersion {
			t.Errorf("%s = %q", config.HeaderAnthropicVersion, got)
		}
		if got := r.Header.Get(config.HeaderContentType); got != config.ContentTypeJSON {
			t.Errorf("%s = %q", config.HeaderContentType, got)
		}

		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decoding request body: %v", err)
		}
		if body["model"] != config.AnthropicModel {
			t.Errorf("model = %v, want %s", body["model"], config.AnthropicModel)
		}
		if body["system"] != config.SystemPrompt {
			t.Error("system prompt not forwarded")
		}

		w.Header().Set(config.HeaderContentType, config.ContentTypeJSON)
		_, _ = io.WriteString(w,
			`{"content":[{"type":"thinking","text":"hmm"},{"type":"text","text":"answer"}]}`)
	}))
	defer server.Close()

	client := ai.NewHTTPClient(apiKey, server.Client())
	client.BaseURL = server.URL

	got, err := client.Complete(t.Context(), config.SystemPrompt, "user prompt")
	if err != nil {
		t.Fatalf("Complete() unexpected error: %v", err)
	}
	if got != "answer" {
		t.Errorf("Complete() = %q, want %q", got, "answer")
	}
}

func TestCompleteErrors(t *testing.T) {
	marshalErr := errors.New("boom")
	transportErr := errors.New("dial failed")
	readErr := errors.New("read failed")

	tests := []struct {
		name    string
		mutate  func(c *ai.HTTPClient)
		wantErr error
	}{
		{
			name: "request body encoding fails",
			mutate: func(c *ai.HTTPClient) {
				c.Marshal = func(any) ([]byte, error) { return nil, marshalErr }
			},
			wantErr: ai.ErrEncodeRequest,
		},
		{
			name:    "request construction fails on an invalid url",
			mutate:  func(c *ai.HTTPClient) { c.BaseURL = "://not a url" },
			wantErr: ai.ErrBuildRequest,
		},
		{
			name:    "transport fails",
			mutate:  func(c *ai.HTTPClient) { c.HTTP = errTransport{err: transportErr} },
			wantErr: ai.ErrRequestFailed,
		},
		{
			name: "response body is unreadable",
			mutate: func(c *ai.HTTPClient) {
				c.HTTP = bodyTransport{status: config.HTTPStatusOK, body: errReader{err: readErr}}
			},
			wantErr: ai.ErrReadBody,
		},
		{
			name: "non-200 status",
			mutate: func(c *ai.HTTPClient) {
				c.HTTP = bodyTransport{
					status: http.StatusTooManyRequests,
					body:   strings.NewReader(`{"error":"rate limited"}`),
				}
			},
			wantErr: ai.ErrUnexpectedStatus,
		},
		{
			name: "response is not json",
			mutate: func(c *ai.HTTPClient) {
				c.HTTP = bodyTransport{
					status: config.HTTPStatusOK,
					body:   strings.NewReader("<html>gateway error</html>"),
				}
			},
			wantErr: ai.ErrDecodeResponse,
		},
		{
			name: "response carries no text block",
			mutate: func(c *ai.HTTPClient) {
				c.HTTP = bodyTransport{
					status: config.HTTPStatusOK,
					body:   strings.NewReader(`{"content":[{"type":"thinking","text":"hmm"}]}`),
				}
			},
			wantErr: ai.ErrNoTextContent,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := ai.NewHTTPClient("key", http.DefaultClient)
			client.BaseURL = "http://127.0.0.1:1"
			tt.mutate(client)

			_, err := client.Complete(t.Context(), "system", "user")
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("Complete() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}
