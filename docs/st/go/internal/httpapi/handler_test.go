package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"ticketqr/internal/analyzer"
	"ticketqr/internal/imageinput"
	"ticketqr/internal/signer"
	"ticketqr/internal/ticket"
	"ticketqr/internal/view"
)

// Real 32x32 images (../../../testdata/images, shared with the Node version): the format check parses
// headers, so bytes that only start like an image are not accepted.
var (
	jpeg     = mustRead("photo.jpg")
	png      = mustRead("photo.png")
	codeRe   = regexp.MustCompile(`^\d{14}-[0-9A-HJKMNP-TV-Z]{10}$`)
	pngMagic = []byte("\x89PNG\r\n\x1a\n")
)

func mustRead(name string) []byte {
	b, err := os.ReadFile("../../../testdata/images/" + name)
	if err != nil {
		panic(err)
	}
	return b
}

type stubVerifier struct {
	res ticket.Verdict
	err error
	got *ticket.CertificateImage // when set, records what the analyzer was given
}

func (s stubVerifier) Verify(_ context.Context, img ticket.CertificateImage) (ticket.Verdict, error) {
	if s.got != nil {
		*s.got = img
	}
	return s.res, s.err
}

func newHandlers(t *testing.T, an ticket.Verifier) *Handlers {
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
		Ports:         ticket.Ports{Verifier: an, Generator: ticket.NewGenerator(10), Logger: logger},
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

// withContentType rewrites the Content-Type of a form request; format gets the request's boundary (%s).
func withContentType(t *testing.T, req Request, format string) Request {
	t.Helper()
	_, params, err := mime.ParseMediaType(req.Headers["content-type"])
	if err != nil {
		t.Fatal(err)
	}
	req.Headers = map[string]string{"content-type": strings.ReplaceAll(format, "%s", params["boundary"])}
	return req
}

// brokenAfterImage is a valid image part followed by a part whose headers never end.
func brokenAfterImage(t *testing.T) Request {
	t.Helper()
	req := formRequest(t, "image", jpeg)
	_, params, _ := mime.ParseMediaType(req.Headers["content-type"])
	body, _ := base64.StdEncoding.DecodeString(req.Body)
	closing := "--" + params["boundary"] + "--\r\n"
	if !bytes.HasSuffix(body, []byte(closing)) {
		t.Fatal("unexpected multipart body")
	}
	body = append(body[:len(body)-len(closing)], "--"+params["boundary"]+"\r\nX-Broken"...)
	req.Body = base64.StdEncoding.EncodeToString(body)
	return req
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

func TestGrantInline(t *testing.T) {
	var sent ticket.CertificateImage
	h := newHandlers(t, stubVerifier{res: ticket.Verdict{Valid: true}, got: &sent})
	res, _ := h.GrantInline(context.Background(), formRequest(t, "image", jpeg))

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

func TestGrantInlineErrors(t *testing.T) {
	big := append(append([]byte{}, jpeg...), make([]byte, imageinput.MaxBytes)...)
	tests := []struct {
		name     string
		analyzer ticket.Verifier
		req      Request
		status   int
		code     string
	}{
		{"json instead of form", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "application/json"}, Body: "{}"}, 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"no boundary", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "multipart/form-data"}, Body: "x"}, 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"broken multipart", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "multipart/form-data; boundary=xyz"}, Body: "garbage"}, 400, "BAD_REQUEST"},
		{"empty boundary", analyzer.AlwaysValid{}, withContentType(t, formRequest(t, "image", jpeg), `multipart/form-data; boundary=""`), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"boundary without value", analyzer.AlwaysValid{}, withContentType(t, formRequest(t, "image", jpeg), "multipart/form-data; boundary"), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"conflicting boundaries", analyzer.AlwaysValid{}, withContentType(t, formRequest(t, "image", jpeg), "multipart/form-data; boundary=%s; boundary=other"), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"garbage after boundary", analyzer.AlwaysValid{}, withContentType(t, formRequest(t, "image", jpeg), "multipart/form-data; boundary=%s x"), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"broken after the image part", analyzer.AlwaysValid{}, brokenAfterImage(t), 400, "BAD_REQUEST"},
		{"missing image field", analyzer.AlwaysValid{}, formRequest(t, "file", jpeg), 400, "BAD_REQUEST"},
		{"empty image", analyzer.AlwaysValid{}, formRequest(t, "image", nil), 400, "BAD_REQUEST"},
		{"not an image", analyzer.AlwaysValid{}, formRequest(t, "image", []byte("hello")), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"too large", analyzer.AlwaysValid{}, formRequest(t, "image", big), 413, "PAYLOAD_TOO_LARGE"},
		{"rejected", stubVerifier{res: ticket.Verdict{Valid: false, Reason: "blurry"}}, formRequest(t, "image", jpeg), 422, "IMAGE_INVALID"},
		{"upstream error", stubVerifier{err: ticket.ErrVerifierUpstream}, formRequest(t, "image", jpeg), 502, "ANALYSIS_UPSTREAM_ERROR"},
		{"timeout", stubVerifier{err: ticket.ErrVerifierTimeout}, formRequest(t, "image", jpeg), 504, "ANALYSIS_TIMEOUT"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res, err := newHandlers(t, tt.analyzer).GrantInline(context.Background(), tt.req)
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if res.StatusCode != tt.status || errorCode(t, res) != tt.code {
				t.Errorf("got %d %s, want %d %s", res.StatusCode, errorCode(t, res), tt.status, tt.code)
			}
		})
	}
}

// TestContentTypeVariants: valid spellings of a multipart Content-Type. The Node tests have the same cases
// except spaces around "=", a known difference (NODE.md 10).
func TestContentTypeVariants(t *testing.T) {
	for _, format := range []string{
		`multipart/form-data; boundary="%s"`,
		"Multipart/Form-Data; boundary=%s",
		"multipart/form-data; boundary=%s;",
		"multipart/form-data ; charset=utf-8; BOUNDARY = %s",
		"multipart/form-data; boundary=%s; boundary=%s",
	} {
		t.Run(format, func(t *testing.T) {
			req := withContentType(t, formRequest(t, "image", jpeg), format)
			res, _ := newHandlers(t, analyzer.AlwaysValid{}).GrantInline(context.Background(), req)
			if res.StatusCode != http.StatusCreated {
				t.Errorf("status = %d, body = %s", res.StatusCode, res.Body)
			}
		})
	}
}

// TestPatternBFlow follows the browser: POST form → 303 → view HTML → img src → PNG.
func TestPatternBFlow(t *testing.T) {
	h := newHandlers(t, analyzer.AlwaysValid{})
	ctx := context.Background()

	res, _ := h.Grant(ctx, formRequest(t, "image", png))
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("grant status = %d, body = %s", res.StatusCode, res.Body)
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

func TestGrantErrorsAreHTML(t *testing.T) {
	tests := []struct {
		name     string
		analyzer ticket.Verifier
		req      Request
		status   int
		code     string
	}{
		{"json instead of form", analyzer.AlwaysValid{}, Request{Headers: map[string]string{"content-type": "application/json"}, Body: "{}"}, 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"missing image field", analyzer.AlwaysValid{}, formRequest(t, "file", jpeg), 400, "BAD_REQUEST"},
		{"not an image", analyzer.AlwaysValid{}, formRequest(t, "image", []byte("hello")), 415, "UNSUPPORTED_MEDIA_TYPE"},
		{"too large", analyzer.AlwaysValid{}, formRequest(t, "image", append(append([]byte{}, jpeg...), make([]byte, imageinput.MaxBytes)...)), 413, "PAYLOAD_TOO_LARGE"},
		{"rejected", stubVerifier{res: ticket.Verdict{Valid: false}}, formRequest(t, "image", jpeg), 422, "IMAGE_INVALID"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res, _ := newHandlers(t, tt.analyzer).Grant(context.Background(), tt.req)
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

// TestGrantInlineWithHTTPAnalyzer checks the real HTTP client end to end: the analysis server's answer or
// failure becomes 201 / 422 / 502 / 504.
func TestGrantInlineWithHTTPAnalyzer(t *testing.T) {
	tests := []struct {
		name   string
		handle http.HandlerFunc
		status int
		code   string
	}{
		{"valid", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, `{"valid":true}`) }, 201, ""},
		{"invalid", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, `{"valid":false}`) }, 422, "IMAGE_INVALID"},
		{"5xx", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(500) }, 502, "ANALYSIS_UPSTREAM_ERROR"},
		{"no answer", hang, 504, "ANALYSIS_TIMEOUT"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(tt.handle)
			defer srv.Close()
			an := analyzer.NewHTTP(analyzer.HTTPConfig{URL: srv.URL, APIKey: "k", Timeout: 100 * time.Millisecond})

			res, _ := newHandlers(t, an).GrantInline(context.Background(), formRequest(t, "image", jpeg))

			if res.StatusCode != tt.status {
				t.Fatalf("status = %d, body = %s", res.StatusCode, res.Body)
			}
			if tt.code != "" && errorCode(t, res) != tt.code {
				t.Errorf("code = %s, want %s", errorCode(t, res), tt.code)
			}
		})
	}
}

// hang never answers. It reads the body first: the server only notices the client giving up (and
// cancels r.Context()) once the body has been consumed; the cap keeps a broken test from hanging.
func hang(_ http.ResponseWriter, r *http.Request) {
	io.Copy(io.Discard, r.Body)
	select {
	case <-r.Context().Done():
	case <-time.After(5 * time.Second):
	}
}

// TestUploadFormats checks the split of responsibilities: the handler detects the format, VerifyAndGrant
// accepts only the formats phones upload, and the bytes reach the analyzer unchanged.
func TestUploadFormats(t *testing.T) {
	for file, want := range map[string]string{
		"photo.jpg": "image/jpeg", "photo.png": "image/png", "photo.heic": "image/heic",
		"photo-mif1.heif": "image/heif", "photo.avif": "image/avif", "photo.webp": "image/webp",
	} {
		t.Run(file, func(t *testing.T) {
			var sent ticket.CertificateImage
			h := newHandlers(t, stubVerifier{res: ticket.Verdict{Valid: true}, got: &sent})
			data := mustRead(file)
			res, _ := h.GrantInline(context.Background(), formRequest(t, "image", data))
			if res.StatusCode != http.StatusCreated || sent.MimeType != want || !bytes.Equal(sent.Data, data) {
				t.Errorf("status %d, mime %q, unchanged %v", res.StatusCode, sent.MimeType, bytes.Equal(sent.Data, data))
			}
		})
	}
	for name, data := range map[string][]byte{
		"text":                  mustRead("not-image.txt"),
		"JPEG magic bytes only": {0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F'},
	} {
		t.Run(name, func(t *testing.T) {
			res, _ := newHandlers(t, analyzer.AlwaysValid{}).GrantInline(context.Background(), formRequest(t, "image", data))
			if res.StatusCode != http.StatusUnsupportedMediaType {
				t.Errorf("status = %d, want 415", res.StatusCode)
			}
		})
	}
}

// TestGrantAcceptJSON checks the SPA path of B-1: Accept: application/json gets the signed QR URL as JSON
// (and JSON errors) instead of a redirect.
func TestGrantAcceptJSON(t *testing.T) {
	h := newHandlers(t, analyzer.AlwaysValid{})
	req := formRequest(t, "image", jpeg)
	req.Headers["accept"] = "application/json"

	res, _ := h.Grant(context.Background(), req)
	if res.StatusCode != http.StatusCreated || !strings.HasPrefix(res.Headers["Content-Type"], "application/json") {
		t.Fatalf("status = %d, content-type = %q, body = %s", res.StatusCode, res.Headers["Content-Type"], res.Body)
	}
	if res.Headers["Location"] != "" || res.Headers["Vary"] != "Accept" {
		t.Errorf("Location = %q, Vary = %q", res.Headers["Location"], res.Headers["Vary"])
	}
	var body struct{ TicketCode, IssuedAt, Sig, QRURL string }
	if err := json.Unmarshal([]byte(res.Body), &body); err != nil {
		t.Fatal(err)
	}
	if !codeRe.MatchString(body.TicketCode) || !strings.HasSuffix(body.IssuedAt, "+09:00") || !h.Signer.Verify(body.TicketCode, body.Sig) {
		t.Fatalf("unexpected body %+v", body)
	}
	if want := "https://api.example.com/v1/tickets/" + body.TicketCode + "/qr?sig=" + url.QueryEscape(body.Sig); body.QRURL != want {
		t.Errorf("qrUrl = %q, want %q", body.QRURL, want)
	}

	// The returned URL serves the QR (B-2), so the SPA can render <img src=qrUrl>.
	res, _ = h.GetQR(context.Background(), signedGet(h, body.TicketCode, body.Sig))
	if res.StatusCode != http.StatusOK || res.Headers["Content-Type"] != "image/png" {
		t.Errorf("qr status = %d", res.StatusCode)
	}

	// Errors are JSON too.
	bad := formRequest(t, "image", []byte("hello"))
	bad.Headers["accept"] = "application/json"
	res, _ = h.Grant(context.Background(), bad)
	if res.StatusCode != http.StatusUnsupportedMediaType || errorCode(t, res) != "UNSUPPORTED_MEDIA_TYPE" {
		t.Errorf("error: status = %d, body = %s", res.StatusCode, res.Body)
	}

	// A browser form (Accept: text/html,...) still gets the redirect.
	form := formRequest(t, "image", jpeg)
	form.Headers["accept"] = "text/html,application/xhtml+xml,*/*;q=0.8"
	if res, _ = h.Grant(context.Background(), form); res.StatusCode != http.StatusSeeOther {
		t.Errorf("form: status = %d, want 303", res.StatusCode)
	}
}

// completedLogs runs fn with a JSON logger and returns the "request completed" entries.
func completedLogs(t *testing.T, h *Handlers, fn func()) []map[string]any {
	t.Helper()
	var buf bytes.Buffer
	h.Logger = slog.New(slog.NewJSONHandler(&buf, nil))
	fn()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("log line is not JSON: %s", line)
		}
		if entry["msg"] == "request completed" {
			out = append(out, entry)
		}
	}
	return out
}

// TestClientLog: the image upload endpoints log the browser's User-Agent and Client Hints (same keys as
// the Node version), other endpoints do not.
func TestClientLog(t *testing.T) {
	const iOS13 = "Mozilla/5.0 (iPhone; CPU iPhone OS 13_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.4 Mobile/15E148 Safari/604.1"
	h := newHandlers(t, analyzer.AlwaysValid{})
	ctx := context.Background()

	withClient := func(req Request) Request {
		req.Headers["user-agent"] = iOS13
		req.Headers["sec-ch-ua"] = `"Chromium";v="138", "Google Chrome";v="138"`
		req.Headers["sec-ch-ua-mobile"] = "?1"
		req.Headers["sec-ch-ua-platform"] = `"Android"`
		return req
	}
	logs := completedLogs(t, h, func() {
		h.GrantInline(ctx, withClient(formRequest(t, "image", jpeg)))
		h.Grant(ctx, withClient(formRequest(t, "image", []byte("not an image")))) // errors are logged too
		h.GetQR(ctx, Request{Headers: map[string]string{"user-agent": iOS13}})
	})
	if len(logs) != 3 {
		t.Fatalf("got %d completion logs, want 3", len(logs))
	}
	for _, entry := range logs[:2] {
		client, ok := entry["client"].(map[string]any)
		if !ok {
			t.Fatalf("%v: no client group", entry["endpoint"])
		}
		want := map[string]any{
			"userAgent":       iOS13,
			"secChUa":         `"Chromium";v="138", "Google Chrome";v="138"`,
			"secChUaMobile":   "?1",
			"secChUaPlatform": `"Android"`,
		}
		for k, v := range want {
			if client[k] != v {
				t.Errorf("%v: client.%s = %v, want %v", entry["endpoint"], k, client[k], v)
			}
		}
		if _, ok := client["secChUaPlatformVersion"]; ok {
			t.Errorf("%v: absent headers must not be logged", entry["endpoint"])
		}
	}
	if logs[1]["status"] != float64(415) {
		t.Errorf("grant status = %v, want 415", logs[1]["status"])
	}
	if _, ok := logs[2]["client"]; ok {
		t.Error("get-qr must not log the client")
	}
}

func TestClientLogLimits(t *testing.T) {
	h := newHandlers(t, analyzer.AlwaysValid{})
	long := strings.Repeat("a", 2000)
	logs := completedLogs(t, h, func() {
		req := formRequest(t, "image", jpeg)
		req.Headers["user-agent"] = long
		h.GrantInline(context.Background(), req)
		h.GrantInline(context.Background(), formRequest(t, "image", jpeg)) // no client headers
	})
	if ua := logs[0]["client"].(map[string]any)["userAgent"].(string); len(ua) != 512 {
		t.Errorf("userAgent length = %d, want 512", len(ua))
	}
	if _, ok := logs[1]["client"]; ok {
		t.Error("an empty client group must be omitted")
	}
}
