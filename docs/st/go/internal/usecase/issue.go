// Package usecase holds the ticket issuing flow shared by patterns A and B.
package usecase

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"ticketqr/go/internal/analyzer"
	"ticketqr/go/internal/apperr"
	"ticketqr/go/internal/imageinput"
	"ticketqr/go/internal/ticketcode"
)

type Issuer struct {
	Analyzer  analyzer.Analyzer
	Generator *ticketcode.Generator
	Logger    *slog.Logger
}

// Issue validates the image, asks the analyzer, and generates a ticket code only when it is valid.
func (i *Issuer) Issue(ctx context.Context, image []byte, declaredMime string) (ticketcode.Ticket, error) {
	mime, err := imageinput.Validate(image, declaredMime)
	if err != nil {
		return ticketcode.Ticket{}, err
	}

	res, err := i.Analyzer.Analyze(ctx, analyzer.Image{Data: image, MimeType: mime})
	switch {
	case errors.Is(err, analyzer.ErrTimeout):
		return ticketcode.Ticket{}, apperr.AnalysisTimeout()
	case err != nil:
		i.Logger.ErrorContext(ctx, "image analysis failed", "error", err)
		return ticketcode.Ticket{}, apperr.AnalysisUpstream()
	case !res.Valid:
		i.Logger.InfoContext(ctx, "image rejected", "reason", res.Reason)
		return ticketcode.Ticket{}, apperr.ImageInvalid("image was rejected")
	}

	t, err := i.Generator.Generate()
	if err != nil {
		return ticketcode.Ticket{}, err
	}
	i.Logger.InfoContext(ctx, "ticket issued",
		"ticketCode", t.Code, "issuedAt", t.IssuedAt.Format(time.RFC3339), "analysisReason", res.Reason)
	return t, nil
}
