// Package analyzer is the client for the external image analysis server: it implements
// ticket.Verifier (clean architecture: an outbound adapter).
//
// Request format is fixed: POST with Content-Type application/octet-stream and the raw image
// bytes (ticket.CertificateImage.Data) as the body. ANALYZER_MODE=mock answers PASS in-process; ANALYZER_MODE=http
// posts to the server (http.go; analyzer-stub/DESIGN.md 3). The API reads only "result" of the response.
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
		return AlwaysPass{}, nil
	case "http":
		return NewHTTP(httpCfg), nil
	default:
		return nil, fmt.Errorf("unsupported ANALYZER_MODE %q", mode)
	}
}

// AlwaysPass is the in-process mock (ANALYZER_MODE=mock): every image passes.
type AlwaysPass struct{}

func (AlwaysPass) Verify(context.Context, ticket.CertificateImage) (ticket.Verdict, error) {
	return ticket.Verdict{Result: ticket.ResultPass}, nil
}
