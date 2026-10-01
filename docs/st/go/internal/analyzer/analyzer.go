// Package analyzer is the client for the external image analysis server.
//
// The server protocol is not decided yet, so only a mock that always returns valid exists.
package analyzer

import (
	"context"
	"errors"
	"fmt"
)

type Image struct {
	Data     []byte
	MimeType string
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

// New returns the analyzer selected by ANALYZER_MODE.
func New(mode string) (Analyzer, error) {
	switch mode {
	case "mock":
		return AlwaysValid{}, nil
	default:
		return nil, fmt.Errorf("unsupported ANALYZER_MODE %q", mode)
	}
}

type AlwaysValid struct{}

func (AlwaysValid) Analyze(context.Context, Image) (Result, error) {
	return Result{Valid: true, Reason: "mock"}, nil
}
