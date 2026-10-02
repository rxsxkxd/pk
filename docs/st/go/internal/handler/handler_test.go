package handler

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"testing"

	"ticketqr/go/internal/analyzer"
	"ticketqr/go/internal/imageinput"
	"ticketqr/go/internal/signer"
	"ticketqr/go/internal/ticketcode"
	"ticketqr/go/internal/usecase"
	"ticketqr/go/internal/view"
)

var (
	jpeg     = []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F'}
	png      = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0}
	codeRe   = regexp.MustCompile(`^\d{14}-[0-9A-HJKMNP-TV-Z]{10}$`)
	pngMagic = png[:8]
)

type stubAnalyzer struct {
	res analyzer.Result
	err error
	got *analyzer.Image // when set, records what the analyzer was given
}

func (s stubAnalyzer) Analyze(_ context.Context, img analyzer.Image) (analyzer.Result, error) {
	if s.got != nil {
		*s.got = img
	}
	return s.res, s.err
}

func newHandlers(t *testing.T, an analyzer.Analyzer) *Handlers {
	t.Helper()
	sg, err := signer.New("test-salt", "")
	if err != nil {
		t.Fatal(err)
	}
	vw, err := view.New()
	if err != nil {
		t.Fatal(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &Handlers{
		PublicBaseURL: "https://api.example.com",
		PublicOrigin:  "https://api.example.com",
		Issuer:        &usecase.Issuer{Analyzer: an, Generator: ticketcode.NewGenerator(10), Logger: logger},
		Signer:        sg,
		View:          vw,
		Logger:        logger,
	}
}

func formRequest(t *testing.T, field string, data []byte) Request {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile(field, "upload.jpg")
	if err != nil {
		t.Fatal(err)
	}
	fw.Write(data)
	mw.Close()
	return Request{
		Headers:         map[string]string{"content-type": mw.FormDataContentType()},
		Body:            base64.StdEncoding.EncodeToString(buf.Bytes()),
		IsBase64Encoded: true,
	}
}

func signedGet(h *Handlers, code, sig string) Request {
	return Request{
		PathParameters:        map[string]string{"ticketCode": code},
		QueryStringParameters: map[string]string{"sig": sig},
	}
}

func errorCode(t *testing.T, res Response) string {
	t.Helper()
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	if err := json.Unmarshal([]byte(res.Body), &body); err != nil {
		t.Fatalf("error body is not JSON: %q", res.Body)
	}
	return body.Error.Code
}

func assertCommonHeaders(t *testing.T, res Response) {
	t.Helper()
	if res.Headers["Cache-Control"] != "no-store" {
		t.Errorf("Cache-Control = %q", res.Headers["Cache-Control"])
	}
	if res.Headers["X-Content-Type-Options"] != "nosniff" {
		t.Errorf("X-Content-Type-Options = %q", res.Headers["X-Content-Type-Options"])
	}
}

func TestIssueInline(t *testing.T) {
	var sent analyzer.Image
	h := newHandlers(t, stubAnalyzer{res: analyzer.Result{Valid: true}, got: &sent})
	res, _ := h.IssueInline(context.Background(), formRequest(t, "image", jpeg))

	if res.StatusCode != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", res.StatusCode, res.Body)
	}
	assertCommonHeaders(t, res)
	if !bytes.Equal(sent.Data, jpeg) {
		t.Errorf("analyzer received %x, want the uploaded bytes unchanged %x", sent.Data, jpeg)
	}
	var body struct {
		TicketCode string `json:"ticketCode"`
		IssuedAt   string `json:"issuedAt"`
		QR         struct {
			MimeType string `json:"mimeType"`
			Data     string `json:"data"`
		} `json:"qr"`
	}
	if err := json.Unmarshal([]byte(res.Body), &body); err != nil {
		t.Fatal(err)
	}
	if !codeRe.MatchString(body.TicketCode) {
		t.Errorf("ticketCode = %q", body.TicketCode)
	}
	if !strings.HasSuffix(body.IssuedAt, "+09:00") {
		t.Errorf("issuedAt = %q, want JST", body.IssuedAt)
	}
	qrPNG, err := base64.StdEncoding.DecodeString(body.QR.Data)
	if err != nil || !bytes.HasPrefix(qrPNG, pngMagic) || body.QR.MimeType != "image/png" {
		t.Errorf("qr is not a base64 PNG (mimeType %q)", body.QR.MimeType)
	}
}

func TestIssueInlineErrors(t *testing.T) {
	big := append(append([]byte{}, jpeg...), make([]byte, imageinput.MaxBytes)...)
	tests := []struct {
		name     string
		analyzer analyzer.Analyzer
		req      Request
		status   int
		code     string
	}{
		{"json instead of form", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "application/json"}, Body: "{}"}, 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"no boundary", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "multipart/form-data"}, Body: "x"}, 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"broken multipart", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "multipart/form-data; boundary=xyz"}, Body: "garbage"}, 400, "BAD_REQUEST"},
		{"missing image field", analyzer.AlwaysValid{}, formRequest(t, "file", jpeg), 400, "BAD_REQUEST"},
		{"empty image", analyzer.AlwaysValid{}, formRequest(t, "image", nil), 400, "BAD_REQUEST"},
		{"not an image", analyzer.AlwaysValid{}, formRequest(t, "image", []byte("hello")), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"too large", analyzer.AlwaysValid{}, formRequest(t, "image", big), 413, "PAYLOAD_TOO_LARGE"},
		{"rejected", stubAnalyzer{res: analyzer.Result{Valid: false, Reason: "blurry"}}, formRequest(t, "image", jpeg), 422, "IMAGE_INVALID"},
		{"upstream error", stubAnalyzer{err: analyzer.ErrUpstream}, formRequest(t, "image", jpeg), 502, "ANALYSIS_UPSTREAM_ERROR"},
		{"timeout", stubAnalyzer{err: analyzer.ErrTimeout}, formRequest(t, "image", jpeg), 504, "ANALYSIS_TIMEOUT"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res, err := newHandlers(t, tt.analyzer).IssueInline(context.Background(), tt.req)
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if res.StatusCode != tt.status || errorCode(t, res) != tt.code {
				t.Errorf("got %d %s, want %d %s", res.StatusCode, errorCode(t, res), tt.status, tt.code)
			}
		})
	}
}

// TestPatternBFlow follows the browser: POST form → 303 → view HTML → img src → PNG.
func TestPatternBFlow(t *testing.T) {
	h := newHandlers(t, analyzer.AlwaysValid{})
	ctx := context.Background()

	res, _ := h.Issue(ctx, formRequest(t, "image", png))
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("issue status = %d, body = %s", res.StatusCode, res.Body)
	}
	assertCommonHeaders(t, res)
	loc, err := url.Parse(res.Headers["Location"])
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`^/v1/tickets/([^/]+)/view$`).FindStringSubmatch(loc.Path)
	if loc.Scheme+"://"+loc.Host != "https://api.example.com" || m == nil || !codeRe.MatchString(m[1]) {
		t.Fatalf("unexpected Location %q", loc)
	}
	code, sig := m[1], loc.Query().Get("sig")

	res, _ = h.GetView(ctx, signedGet(h, code, sig))
	if res.StatusCode != http.StatusOK || !strings.HasPrefix(res.Headers["Content-Type"], "text/html") {
		t.Fatalf("view status = %d, content-type = %q", res.StatusCode, res.Headers["Content-Type"])
	}
	if !strings.Contains(res.Headers["Content-Security-Policy"], "img-src https://api.example.com") {
		t.Errorf("CSP = %q", res.Headers["Content-Security-Policy"])
	}
	wantImg := `src="https://api.example.com/v1/tickets/` + code + `/qr?sig=` + url.QueryEscape(sig) + `"`
	if !strings.Contains(res.Body, wantImg) || !strings.Contains(res.Body, `data-ticket-code="`+code+`"`) {
		t.Fatalf("view body missing %s:\n%s", wantImg, res.Body)
	}

	res, _ = h.GetQR(ctx, signedGet(h, code, sig))
	if res.StatusCode != http.StatusOK || res.Headers["Content-Type"] != "image/png" || !res.IsBase64Encoded {
		t.Fatalf("qr status = %d, content-type = %q", res.StatusCode, res.Headers["Content-Type"])
	}
	qrPNG, _ := base64.StdEncoding.DecodeString(res.Body)
	if !bytes.HasPrefix(qrPNG, pngMagic) {
		t.Error("qr body is not PNG")
	}
}

func TestIssueErrorsAreHTML(t *testing.T) {
	tests := []struct {
		name     string
		analyzer analyzer.Analyzer
		req      Request
		status   int
		code     string
	}{
		{"json instead of form", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "application/json"}, Body: "{}"}, 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"missing image field", analyzer.AlwaysValid{}, formRequest(t, "file", jpeg), 400, "BAD_REQUEST"},
		{"not an image", analyzer.AlwaysValid{}, formRequest(t, "image", []byte("hello")), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"too large", analyzer.AlwaysValid{}, formRequest(t, "image", append(append([]byte{}, jpeg...), make([]byte, imageinput.MaxBytes)...)), 413, "PAYLOAD_TOO_LARGE"},
		{"rejected", stubAnalyzer{res: analyzer.Result{Valid: false}}, formRequest(t, "image", jpeg), 422, "IMAGE_INVALID"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res, _ := newHandlers(t, tt.analyzer).Issue(context.Background(), tt.req)
			if res.StatusCode != tt.status {
				t.Errorf("status = %d, want %d", res.StatusCode, tt.status)
			}
			if !strings.HasPrefix(res.Headers["Content-Type"], "text/html") || !strings.Contains(res.Body, `data-error-code="`+tt.code+`"`) {
				t.Errorf("want HTML error view with %s, got %q", tt.code, res.Body)
			}
			if res.Headers["Location"] != "" {
				t.Error("error response must not redirect")
			}
		})
	}
}

func TestSignatureRequired(t *testing.T) {
	h := newHandlers(t, analyzer.AlwaysValid{})
	code := "20261001194300-7K3QX9MZ2P"
	other := "20261001000000-0000000000"
	cases := map[string]Request{
		"missing sig":        signedGet(h, code, ""),
		"sig for other code": signedGet(h, code, h.Signer.Sign(other)),
		"garbage sig":        signedGet(h, code, "xxxxxxxxxxxxxxxxxxxxxx"),
		"missing code":       {QueryStringParameters: map[string]string{"sig": h.Signer.Sign(code)}},
	}
	for name, req := range cases {
		t.Run(name, func(t *testing.T) {
			res, _ := h.GetView(context.Background(), req)
			if res.StatusCode != http.StatusForbidden || !strings.Contains(res.Body, `data-error-code="FORBIDDEN"`) {
				t.Errorf("view: status = %d body = %q", res.StatusCode, res.Body)
			}
			res, _ = h.GetQR(context.Background(), req)
			if res.StatusCode != http.StatusForbidden || errorCode(t, res) != "FORBIDDEN" {
				t.Errorf("qr: status = %d body = %q", res.StatusCode, res.Body)
			}
		})
	}
}

func TestViewEscapesTicketCode(t *testing.T) {
	// The code is not format-checked, so a signed but hostile value must still be escaped.
	h := newHandlers(t, analyzer.AlwaysValid{})
	code := `"><script>alert(1)</script>`
	res, _ := h.GetView(context.Background(), signedGet(h, code, h.Signer.Sign(code)))
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", res.StatusCode)
	}
	if strings.Contains(res.Body, "<script>") {
		t.Fatalf("ticket code was not escaped:\n%s", res.Body)
	}
}
