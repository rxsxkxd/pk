// Package usecase holds the ticket issuing flow shared by patterns A and B.
package usecase

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"ticketqr/internal/analyzer"
	"ticketqr/internal/apperr"
	"ticketqr/internal/ticketcode"
)

type Issuer struct {
	Analyzer  analyzer.Analyzer
	Generator *ticketcode.Generator
	Logger    *slog.Logger
}

// Upload is an image exactly as received, with the format detected by the HTTP layer ("" if unknown).
type Upload struct {
	Data         []byte
	DetectedType string
}

// acceptedTypes are the formats iPhone and major Android phones upload as-is (business rule).
var acceptedTypes = map[string]bool{
	"image/jpeg": true, "image/png": true, "image/heic": true, "image/heif": true,
	"image/avif": true, "image/webp": true,
}

// Issue accepts the upload by the business rules, asks the analyzer, and generates a ticket code only
// when the image is valid.
func (i *Issuer) Issue(ctx context.Context, up Upload) (ticketcode.Ticket, error) {
	if len(up.Data) == 0 {
		return ticketcode.Ticket{}, apperr.BadRequest("image is empty")
	}
	if !acceptedTypes[up.DetectedType] {
		return ticketcode.Ticket{}, apperr.UnsupportedMediaType("image must be JPEG, PNG, HEIC/HEIF, AVIF or WebP")
	}

	res, err := i.Analyzer.Analyze(ctx, analyzer.Image{Data: up.Data, MimeType: up.DetectedType})
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
