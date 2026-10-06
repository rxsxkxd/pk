// Package httpapi is the HTTP layer of the ticket QR API (clean architecture: an inbound adapter). It
// converts API Gateway HTTP API (payload v2) events to calls of package ticket and back: routing, upload
// reading, signed URLs, error responses (errors.go maps the business errors of ticket) and the HTML views.
package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"ticketqr/internal/imageinput"
	"ticketqr/internal/qr"
	"ticketqr/internal/signer"
	"ticketqr/internal/ticket"
	"ticketqr/internal/view"
)

type (
	Request  = events.APIGatewayV2HTTPRequest
	Response = events.APIGatewayV2HTTPResponse
)

type Handlers struct {
	PublicBaseURL string
	PublicOrigin  string
	Ports         ticket.Ports
	Signer        *signer.Signer
	View          *view.Renderer
	Logger        *slog.Logger
}

// GrantInline is pattern A (the QR inline grant API): POST /v1/tickets/qr-inline (multipart image in, JSON with base64 QR out).
func (h *Handlers) GrantInline(ctx context.Context, req Request) (Response, error) {
	return h.run(ctx, req, "grant-inline", h.jsonError, func() (Response, error) {
		img, err := readUpload(req)
		if err != nil {
			return Response{}, err
		}
		t, err := ticket.VerifyAndGrant(ctx, h.Ports, img)
		if err != nil {
			return Response{}, err
		}
		png, err := qr.PNG(t.Code)
		if err != nil {
			return Response{}, err
		}

		type qrOut struct {
			MimeType string `json:"mimeType"`
			Data     string `json:"data"`
		}
		out, err := json.Marshal(struct {
			TicketCode string `json:"ticketCode"`
			IssuedAt   string `json:"issuedAt"`
			QR         qrOut  `json:"qr"`
		}{t.Code, t.IssuedAt.Format(time.RFC3339), qrOut{"image/png", base64.StdEncoding.EncodeToString(png)}})
		if err != nil {
			return Response{}, err
		}
		return jsonResponse(http.StatusCreated, out), nil
	})
}

// Grant is pattern B-1 (the ticket grant API): POST /v1/tickets (multipart image). The reply depends on Accept:
//   - a browser form (no application/json) gets 303 to the view (B-3), errors as HTML;
//   - a client asking for application/json (the SPA) gets 201 JSON with the signed QR URL, errors as JSON.
func (h *Handlers) Grant(ctx context.Context, req Request) (Response, error) {
	asJSON := acceptsJSON(req)
	onError := h.htmlError
	if asJSON {
		onError = h.jsonError
	}
	return h.run(ctx, req, "grant", onError, func() (Response, error) {
		img, err := readUpload(req)
		if err != nil {
			return Response{}, err
		}
		t, err := ticket.VerifyAndGrant(ctx, h.Ports, img)
		if err != nil {
			return Response{}, err
		}
		if !asJSON {
			return Response{
				StatusCode: http.StatusSeeOther,
				Headers:    withCommon(map[string]string{"Location": h.ticketURL(t.Code, "view"), "Vary": "Accept"}),
			}, nil
		}
		out, err := json.Marshal(struct {
			TicketCode string `json:"ticketCode"`
			IssuedAt   string `json:"issuedAt"`
			Sig        string `json:"sig"`
			QRURL      string `json:"qrUrl"`
		}{t.Code, t.IssuedAt.Format(time.RFC3339), h.Signer.Sign(t.Code), h.ticketURL(t.Code, "qr")})
		if err != nil {
			return Response{}, err
		}
		res := jsonResponse(http.StatusCreated, out)
		res.Headers["Vary"] = "Accept"
		return res, nil
	})
}

// GetView is pattern B-3: GET /v1/tickets/{ticketCode}/view?sig=...
func (h *Handlers) GetView(ctx context.Context, req Request) (Response, error) {
	return h.run(ctx, req, "get-view", h.htmlError, func() (Response, error) {
		code, err := h.verified(req)
		if err != nil {
			return Response{}, err
		}
		body, err := h.View.Ticket(code, h.ticketURL(code, "qr"))
		if err != nil {
			return Response{}, err
		}
		return h.htmlResponse(http.StatusOK, body), nil
	})
}

// GetQR is pattern B-2: GET /v1/tickets/{ticketCode}/qr?sig=...
func (h *Handlers) GetQR(ctx context.Context, req Request) (Response, error) {
	return h.run(ctx, req, "get-qr", h.jsonError, func() (Response, error) {
		code, err := h.verified(req)
		if err != nil {
			return Response{}, err
		}
		png, err := qr.PNG(code)
		if err != nil {
			return Response{}, err
		}
		return Response{
			StatusCode:      http.StatusOK,
			Headers:         withCommon(map[string]string{"Content-Type": "image/png"}),
			Body:            base64.StdEncoding.EncodeToString(png),
			IsBase64Encoded: true,
		}, nil
	})
}

// run logs the request and turns any error into the endpoint's error format.
// It never returns a Go error, so API Gateway always receives our response.
func (h *Handlers) run(ctx context.Context, req Request, endpoint string,
	onError func(*apiError) Response, fn func() (Response, error)) (Response, error) {
	start := time.Now()
	log := h.Logger.With("requestId", req.RequestContext.RequestID, "endpoint", endpoint)

	res, err := fn()
	if err != nil {
		appErr := toAPIError(err)
		if appErr.Status >= 500 {
			log.ErrorContext(ctx, "request failed", "error", err)
		}
		res = onError(appErr)
	}
	fields := []any{"status", res.StatusCode, "durationMs", time.Since(start).Milliseconds()}
	if clientEndpoints[endpoint] {
		fields = append(fields, clientAttr(req))
	}
	log.InfoContext(ctx, "request completed", fields...)
	return res, nil
}

// clientEndpoints receive images from browsers. Their completion log also records what the browser says
// about itself, so browser and OS versions can be counted in CloudWatch Logs (DESIGN.md 10).
var clientEndpoints = map[string]bool{"grant-inline": true, "grant": true}

// clientHeaders maps log keys to the request headers logged as-is: the User-Agent and the User-Agent
// Client Hints (low-entropy ones are sent by Chromium by default; the platform version only when asked).
var clientHeaders = [][2]string{
	{"userAgent", "User-Agent"},
	{"secChUa", "Sec-CH-UA"},
	{"secChUaMobile", "Sec-CH-UA-Mobile"},
	{"secChUaPlatform", "Sec-CH-UA-Platform"},
	{"secChUaPlatformVersion", "Sec-CH-UA-Platform-Version"},
}

// maxClientHeaderLen bounds each logged header value (they are client-controlled).
const maxClientHeaderLen = 512

// clientAttr returns the "client" log group with the headers present in req (an empty group is omitted).
func clientAttr(req Request) slog.Attr {
	var attrs []any
	for _, h := range clientHeaders {
		v := header(req, h[1])
		if v == "" {
			continue
		}
		if len(v) > maxClientHeaderLen {
			v = strings.ToValidUTF8(v[:maxClientHeaderLen], "")
		}
		attrs = append(attrs, slog.String(h[0], v))
	}
	return slog.Group("client", attrs...)
}

func (h *Handlers) verified(req Request) (string, error) {
	code := req.PathParameters["ticketCode"]
	if code == "" || !h.Signer.Verify(code, req.QueryStringParameters["sig"]) {
		return "", forbidden()
	}
	return code, nil
}

func (h *Handlers) ticketURL(code, resource string) string {
	return h.PublicBaseURL + "/v1/tickets/" + url.PathEscape(code) + "/" + resource +
		"?sig=" + url.QueryEscape(h.Signer.Sign(code))
}

func (h *Handlers) jsonError(e *apiError) Response {
	type errBody struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	body, _ := json.Marshal(struct {
		Error errBody `json:"error"`
	}{errBody{e.Code, e.Message}})
	return jsonResponse(e.Status, body)
}

func (h *Handlers) htmlError(e *apiError) Response {
	body, err := h.View.Error(e.Code, e.Message)
	if err != nil {
		return Response{StatusCode: e.Status, Headers: withCommon(map[string]string{"Content-Type": "text/plain; charset=utf-8"}), Body: e.Code}
	}
	return h.htmlResponse(e.Status, body)
}

func (h *Handlers) htmlResponse(status int, body []byte) Response {
	return Response{
		StatusCode: status,
		Headers: withCommon(map[string]string{
			"Content-Type":            "text/html; charset=utf-8",
			"Content-Security-Policy": "default-src 'none'; img-src " + h.PublicOrigin + "; style-src 'unsafe-inline'",
			"Referrer-Policy":         "no-referrer",
		}),
		Body: string(body),
	}
}

func jsonResponse(status int, body []byte) Response {
	return Response{
		StatusCode: status,
		Headers:    withCommon(map[string]string{"Content-Type": "application/json; charset=utf-8"}),
		Body:       string(body),
	}
}

func withCommon(h map[string]string) map[string]string {
	h["Cache-Control"] = "no-store"
	h["X-Content-Type-Options"] = "nosniff"
	return h
}

func requestBody(req Request) ([]byte, error) {
	if !req.IsBase64Encoded {
		return []byte(req.Body), nil
	}
	b, err := base64.StdEncoding.DecodeString(req.Body)
	if err != nil {
		return nil, badRequest("invalid request body encoding")
	}
	return b, nil
}

// acceptsJSON reports whether the client asked for a JSON reply (Accept contains application/json).
func acceptsJSON(req Request) bool {
	return strings.Contains(strings.ToLower(header(req, "Accept")), "application/json")
}

// header looks up a header case-insensitively (API Gateway v2 lowercases names, local adapter may not).
func header(req Request, name string) string {
	for k, v := range req.Headers {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

// readUpload reads the certificate image from the multipart "image" field, enforces the runtime size
// limit and detects the format.
// Whether the format is accepted is decided by ticket.VerifyAndGrant.
func readUpload(req Request) (ticket.CertificateImage, error) {
	data, err := readFormImage(req)
	if err != nil {
		return ticket.CertificateImage{}, err
	}
	if len(data) > imageinput.MaxBytes {
		return ticket.CertificateImage{}, payloadTooLarge(fmt.Sprintf("image must be %d bytes or less", imageinput.MaxBytes))
	}
	return ticket.CertificateImage{Data: data, MimeType: imageinput.Detect(data)}, nil
}

// readFormImage returns the raw bytes of the multipart "image" field (the first one). The part's own
// Content-Type is ignored; the format is detected from magic bytes later. The whole body must be valid
// multipart, as in the Node version: the body is already in memory on Lambda, so there is nothing to
// gain from stopping at the image part.
func readFormImage(req Request) ([]byte, error) {
	mt, params, err := mime.ParseMediaType(header(req, "Content-Type"))
	if err != nil || mt != "multipart/form-data" || params["boundary"] == "" {
		return nil, unsupportedMediaType("Content-Type must be multipart/form-data")
	}
	body, err := requestBody(req)
	if err != nil {
		return nil, err
	}
	mr := multipart.NewReader(bytes.NewReader(body), params["boundary"])
	var data []byte
	found := false
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, badRequest("invalid multipart body")
		}
		if found || part.FormName() != "image" {
			continue
		}
		if data, err = io.ReadAll(io.LimitReader(part, imageinput.MaxBytes+1)); err != nil {
			return nil, badRequest("invalid multipart body")
		}
		found = true
	}
	if !found {
		return nil, badRequest("image is required")
	}
	return data, nil
}
