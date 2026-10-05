// Package handler converts API Gateway HTTP API (payload v2) events to use case calls and back.
package handler

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

	"ticketqr/go/internal/apperr"
	"ticketqr/go/internal/imageinput"
	"ticketqr/go/internal/qr"
	"ticketqr/go/internal/signer"
	"ticketqr/go/internal/usecase"
	"ticketqr/go/internal/view"
)

type (
	Request  = events.APIGatewayV2HTTPRequest
	Response = events.APIGatewayV2HTTPResponse
)

type Handlers struct {
	PublicBaseURL string
	PublicOrigin  string
	Issuer        *usecase.Issuer
	Signer        *signer.Signer
	View          *view.Renderer
	Logger        *slog.Logger
}

// IssueInline is pattern A: POST /v1/tickets/qr-inline (multipart image in, JSON with base64 QR out).
func (h *Handlers) IssueInline(ctx context.Context, req Request) (Response, error) {
	return h.run(ctx, req, "issue-inline", h.jsonError, func() (Response, error) {
		upload, err := readUpload(req)
		if err != nil {
			return Response{}, err
		}
		t, err := h.Issuer.Issue(ctx, upload)
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

// Issue is pattern B-1: POST /v1/tickets (multipart image). The reply depends on Accept:
//   - a browser form (no application/json) gets 303 to the view (B-3), errors as HTML;
//   - a client asking for application/json (the SPA) gets 201 JSON with the signed QR URL, errors as JSON.
func (h *Handlers) Issue(ctx context.Context, req Request) (Response, error) {
	asJSON := acceptsJSON(req)
	onError := h.htmlError
	if asJSON {
		onError = h.jsonError
	}
	return h.run(ctx, req, "issue", onError, func() (Response, error) {
		upload, err := readUpload(req)
		if err != nil {
			return Response{}, err
		}
		t, err := h.Issuer.Issue(ctx, upload)
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
	onError func(*apperr.Error) Response, fn func() (Response, error)) (Response, error) {
	start := time.Now()
	log := h.Logger.With("requestId", req.RequestContext.RequestID, "endpoint", endpoint)

	res, err := fn()
	if err != nil {
		appErr := apperr.From(err)
		if appErr.Status >= 500 {
			log.ErrorContext(ctx, "request failed", "error", err)
		}
		res = onError(appErr)
	}
	log.InfoContext(ctx, "request completed",
		"status", res.StatusCode, "durationMs", time.Since(start).Milliseconds())
	return res, nil
}

func (h *Handlers) verified(req Request) (string, error) {
	code := req.PathParameters["ticketCode"]
	if code == "" || !h.Signer.Verify(code, req.QueryStringParameters["sig"]) {
		return "", apperr.Forbidden()
	}
	return code, nil
}

func (h *Handlers) ticketURL(code, resource string) string {
	return h.PublicBaseURL + "/v1/tickets/" + url.PathEscape(code) + "/" + resource +
		"?sig=" + url.QueryEscape(h.Signer.Sign(code))
}

func (h *Handlers) jsonError(e *apperr.Error) Response {
	type errBody struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	body, _ := json.Marshal(struct {
		Error errBody `json:"error"`
	}{errBody{e.Code, e.Message}})
	return jsonResponse(e.Status, body)
}

func (h *Handlers) htmlError(e *apperr.Error) Response {
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
		return nil, apperr.BadRequest("invalid request body encoding")
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

// readUpload reads the multipart "image" field, enforces the runtime size limit and detects the format.
// Whether the format is accepted is decided by the use case.
func readUpload(req Request) (usecase.Upload, error) {
	data, err := readFormImage(req)
	if err != nil {
		return usecase.Upload{}, err
	}
	if len(data) > imageinput.MaxBytes {
		return usecase.Upload{}, apperr.PayloadTooLarge(fmt.Sprintf("image must be %d bytes or less", imageinput.MaxBytes))
	}
	return usecase.Upload{Data: data, DetectedType: imageinput.Detect(data)}, nil
}

// readFormImage returns the raw bytes of the multipart "image" field (the first one). The part's own
// Content-Type is ignored; the format is detected from magic bytes later. The whole body must be valid
// multipart, as in the Node version: the body is already in memory on Lambda, so there is nothing to
// gain from stopping at the image part.
func readFormImage(req Request) ([]byte, error) {
	mt, params, err := mime.ParseMediaType(header(req, "Content-Type"))
	if err != nil || mt != "multipart/form-data" || params["boundary"] == "" {
		return nil, apperr.UnsupportedMediaType("Content-Type must be multipart/form-data")
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
			return nil, apperr.BadRequest("invalid multipart body")
		}
		if found || part.FormName() != "image" {
			continue
		}
		if data, err = io.ReadAll(io.LimitReader(part, imageinput.MaxBytes+1)); err != nil {
			return nil, apperr.BadRequest("invalid multipart body")
		}
		found = true
	}
	if !found {
		return nil, apperr.BadRequest("image is required")
	}
	return data, nil
}
