// Package analyzer is the client for the external image analysis server: it implements
// ticket.Verifier (clean architecture: an outbound adapter).
//
// Request format is fixed: POST with Content-Type application/octet-stream and the raw image
// bytes (ticket.CertificateImage.Data) as the body. ANALYZER_MODE=mock answers valid in-process; ANALYZER_MODE=http
// posts to the server (http.go) using the provisional protocol in analyzer-stub/DESIGN.md 3.
package analyzer

import (
	"context"
	"fmt"

	"ticketqr/internal/ticket"
)

// New returns the analyzer selected by ANALYZER_MODE. httpCfg is used only for "http".
func New(mode string, httpCfg HTTPConfig) (ticket.Verifier, error) {
	switch mode {
	case "mock":
		return AlwaysValid{}, nil
	case "http":
		return NewHTTP(httpCfg), nil
	default:
		return nil, fmt.Errorf("unsupported ANALYZER_MODE %q", mode)
	}
}

type AlwaysValid struct{}

func (AlwaysValid) Verify(context.Context, ticket.CertificateImage) (ticket.Verdict, error) {
	return ticket.Verdict{Valid: true, Reason: "mock"}, nil
}
