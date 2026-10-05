// Package analyzer is the client for the external image analysis server.
//
// Request format is fixed: POST with Content-Type application/octet-stream and the raw image
// bytes (Image.Data) as the body. ANALYZER_MODE=mock answers valid in-process; ANALYZER_MODE=http
// posts to the server (http.go) using the provisional protocol in analyzer-stub/DESIGN.md 3.
package analyzer

import (
	"context"
	"errors"
	"fmt"
)

type Image struct {
	Data     []byte // sent as-is as the application/octet-stream body
	MimeType string // detected from the file header; not part of the request until the protocol says so
}

type Result struct {
	Valid  bool
	Reason string
}

type Analyzer interface {
	Analyze(ctx context.Context, img Image) (Result, error)
}

// Errors a real client must wrap so the caller can map them to 502 / 504.
var (
	ErrUpstream = errors.New("analyzer upstream error")
	ErrTimeout  = errors.New("analyzer timeout")
)

// New returns the analyzer selected by ANALYZER_MODE. httpCfg is used only for "http".
func New(mode string, httpCfg HTTPConfig) (Analyzer, error) {
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

func (AlwaysValid) Analyze(context.Context, Image) (Result, error) {
	return Result{Valid: true, Reason: "mock"}, nil
}
