package analyzer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"ticketqr/internal/ticket"
)

// reply scripts one response of the test server.
type reply func(w http.ResponseWriter, r *http.Request)

func status(code int, body string) reply {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		io.WriteString(w, body)
	}
}

// hang never answers until the client gives up (the server above has already read the body, so it
// notices the disconnect); the cap keeps a broken test from hanging.
var hang reply = func(_ http.ResponseWriter, r *http.Request) {
	select {
	case <-r.Context().Done():
	case <-time.After(5 * time.Second):
	}
}

type received struct {
	header http.Header
	body   []byte
}

// server answers with the scripted replies in order and records every request it receives.
func server(t *testing.T, script ...reply) (*HTTP, *[]received) {
	t.Helper()
	var mu sync.Mutex
	var got []received
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, received{r.Header.Clone(), body})
		next := status(599, "")
		if len(script) > 0 {
			next, script = script[0], script[1:]
		}
		mu.Unlock()
		next(w, r)
	}))
	t.Cleanup(srv.Close)
	return NewHTTP(HTTPConfig{URL: srv.URL + "/v1/analyze", APIKey: "k", Timeout: 200 * time.Millisecond}), &got
}

func TestHTTPWithoutAPIKeySendsNoHeader(t *testing.T) {
	a, got := server(t, status(200, `{"result":"PASS"}`))
	a.cfg.APIKey = ""
	if _, err := a.Verify(context.Background(), ticket.CertificateImage{Data: jpeg, MimeType: "image/jpeg"}); err != nil {
		t.Fatal(err)
	}
	if _, ok := (*got)[0].header["X-Api-Key"]; ok {
		t.Errorf("x-api-key sent without a key: %v", (*got)[0].header)
	}
}

var jpeg = []byte{0xFF, 0xD8, 0xFF, 0xE0, 'p', 'h', 'o', 't', 'o'}

func TestHTTPPostsImageUnchanged(t *testing.T) {
	a, got := server(t, status(200, `{"confidence":0.97,"detected":"certificate","reason":"ok","result":"PASS","status":200}`))
	res, err := a.Verify(context.Background(), ticket.CertificateImage{Data: jpeg, MimeType: "image/jpeg"})
	if err != nil || res != (ticket.Verdict{Result: ticket.ResultPass}) {
		t.Fatalf("Analyze = %+v, %v", res, err)
	}
	if len(*got) != 1 {
		t.Fatalf("requests = %d", len(*got))
	}
	r := (*got)[0]
	if r.header.Get("Content-Type") != "application/octet-stream" || r.header.Get("X-Api-Key") != "k" {
		t.Errorf("headers = %v", r.header)
	}
	if !bytes.Equal(r.body, jpeg) {
		t.Errorf("body = %x, want the image bytes unchanged", r.body)
	}
}

// REJECT and RETRY are results, not errors of the client; only "result" is read.
func TestHTTPRejectAndRetryAreResults(t *testing.T) {
	for _, want := range []ticket.Result{ticket.ResultReject, ticket.ResultRetry} {
		a, _ := server(t, status(200, `{"confidence":0.5,"detected":"x","reason":"y","result":"`+string(want)+`","status":200}`))
		res, err := a.Verify(context.Background(), ticket.CertificateImage{Data: jpeg})
		if err != nil || res.Result != want {
			t.Errorf("Analyze = %+v, %v; want %s", res, err, want)
		}
	}
}

func TestHTTPRetries(t *testing.T) {
	ok := status(200, `{"result":"PASS"}`)
	tests := []struct {
		name    string
		script  []reply
		calls   int
		wantErr error // nil = PASS
	}{
		{"5xx is retried once and succeeds", []reply{status(500, `{}`), ok}, 2, nil},
		{"no answer is retried once and succeeds", []reply{hang, ok}, 2, nil},
		{"5xx twice is an upstream error", []reply{status(500, `{}`), status(502, `{}`)}, 2, ticket.ErrVerifierUpstream},
		{"no answer twice is a timeout", []reply{hang, hang}, 2, ticket.ErrVerifierTimeout},
		{"4xx is not retried", []reply{status(401, `{}`)}, 1, ticket.ErrVerifierUpstream},
		{"malformed body is not retried", []reply{status(200, `{"result":true}`)}, 1, ticket.ErrVerifierUpstream},
		{"missing result is not retried", []reply{status(200, `{"reason":"x"}`)}, 1, ticket.ErrVerifierUpstream},
		{"unknown result is not retried", []reply{status(200, `{"result":"pass"}`)}, 1, ticket.ErrVerifierUpstream},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, got := server(t, tt.script...)
			res, err := a.Verify(context.Background(), ticket.CertificateImage{Data: jpeg})
			if tt.wantErr == nil {
				if err != nil || res.Result != ticket.ResultPass {
					t.Errorf("Analyze = %+v, %v; want PASS", res, err)
				}
			} else if !errors.Is(err, tt.wantErr) {
				t.Errorf("err = %v, want %v", err, tt.wantErr)
			}
			if len(*got) != tt.calls {
				t.Errorf("requests = %d, want %d", len(*got), tt.calls)
			}
		})
	}
}

func TestHTTPConnectionRefusedIsUpstream(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close() // nothing listens there any more
	a := NewHTTP(HTTPConfig{URL: url, APIKey: "k", Timeout: time.Second})
	if _, err := a.Verify(context.Background(), ticket.CertificateImage{Data: jpeg}); !errors.Is(err, ticket.ErrVerifierUpstream) {
		t.Errorf("err = %v, want ticket.ErrVerifierUpstream", err)
	}
}

func TestNewModes(t *testing.T) {
	if a, err := New("mock", HTTPConfig{}); err != nil || a != (AlwaysPass{}) {
		t.Errorf("mock: %v, %v", a, err)
	}
	if a, err := New("http", HTTPConfig{URL: "http://x/v1/analyze"}); err != nil || a == nil {
		t.Errorf("http: %v, %v", a, err)
	}
	if _, err := New("nope", HTTPConfig{}); err == nil {
		t.Error("unknown mode must fail")
	}
}

// Every response body is logged as it came: not parsed, for 2xx and other statuses alike.
func TestHTTPLogsTheRawResponseBody(t *testing.T) {
	pass := `{"confidence":0.97,"detected":"certificate","reason":"ok","result":"PASS","status":200}`
	tests := []struct {
		name   string
		reply  reply
		status int
		body   string
		level  string
	}{
		{"2xx", status(200, pass), 200, pass, "INFO"},
		{"4xx", status(401, `{"error":"invalid api key"}`), 401, `{"error":"invalid api key"}`, "WARN"},
		{"not JSON", status(502, "<html>bad gateway</html>"), 502, "<html>bad gateway</html>", "WARN"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, _ := server(t, tt.reply, tt.reply)
			var buf bytes.Buffer
			a.cfg.Logger = slog.New(slog.NewJSONHandler(&buf, nil))
			_, _ = a.Verify(context.Background(), ticket.CertificateImage{Data: jpeg})

			var line struct {
				Level  string `json:"level"`
				Msg    string `json:"msg"`
				Status int    `json:"status"`
				Body   string `json:"body"`
			}
			if err := json.Unmarshal(bytes.SplitN(buf.Bytes(), []byte("\n"), 2)[0], &line); err != nil {
				t.Fatalf("log = %q: %v", buf.String(), err)
			}
			if line.Msg != "analyzer response" || line.Level != tt.level || line.Status != tt.status || line.Body != tt.body {
				t.Errorf("log = %+v, want %s %d %q", line, tt.level, tt.status, tt.body)
			}
		})
	}
}
