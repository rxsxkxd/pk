package analyzer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"ticketqr/internal/ticket"
)

// HTTPConfig configures the client for ANALYZER_MODE=http.
type HTTPConfig struct {
	URL     string
	APIKey  string
	Timeout time.Duration // per attempt
}

// HTTP posts the image as-is (application/octet-stream, x-api-key) to the analysis server. It retries
// once on 5xx, timeout or a transport error; 4xx and malformed responses are not retried.
type HTTP struct {
	cfg    HTTPConfig
	client *http.Client
}

const maxResponseBytes = 1 << 20

func NewHTTP(cfg HTTPConfig) *HTTP {
	return &HTTP{cfg: cfg, client: &http.Client{}}
}

func (h *HTTP) Verify(ctx context.Context, img ticket.CertificateImage) (ticket.Verdict, error) {
	res, retry, err := h.attempt(ctx, img)
	if err != nil && retry {
		res, _, err = h.attempt(ctx, img)
	}
	return res, err
}

// attempt sends one request. The bool reports whether a failure is worth retrying.
func (h *HTTP) attempt(ctx context.Context, img ticket.CertificateImage) (ticket.Verdict, bool, error) {
	ctx, cancel := context.WithTimeout(ctx, h.cfg.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.cfg.URL, bytes.NewReader(img.Data))
	if err != nil {
		return ticket.Verdict{}, false, fmt.Errorf("%w: build request: %v", ticket.ErrVerifierUpstream, err)
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("X-Api-Key", h.cfg.APIKey)

	resp, err := h.client.Do(req)
	if err != nil {
		return ticket.Verdict{}, true, transportError(ctx, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return ticket.Verdict{}, true, transportError(ctx, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return ticket.Verdict{}, resp.StatusCode >= 500, fmt.Errorf("%w: analyzer returned %d", ticket.ErrVerifierUpstream, resp.StatusCode)
	}
	res, err := parseResponse(body)
	if err != nil {
		return ticket.Verdict{}, false, fmt.Errorf("%w: bad analyzer response: %v", ticket.ErrVerifierUpstream, err)
	}
	return res, false, nil
}

// transportError wraps a failed send or body read as ticket.ErrVerifierTimeout when the deadline passed, else ticket.ErrVerifierUpstream.
func transportError(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("%w: %v", ticket.ErrVerifierTimeout, err)
	}
	return fmt.Errorf("%w: %v", ticket.ErrVerifierUpstream, err)
}

// parseResponse reads the provisional response format {"valid": bool, "reason": string}
// (analyzer-stub/DESIGN.md 3.2). Replace only this when the real server's format is decided.
func parseResponse(body []byte) (ticket.Verdict, error) {
	var out struct {
		Valid  *bool  `json:"valid"`
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return ticket.Verdict{}, err
	}
	if out.Valid == nil {
		return ticket.Verdict{}, errors.New(`"valid" must be a boolean`)
	}
	return ticket.Verdict{Valid: *out.Valid, Reason: out.Reason}, nil
}
