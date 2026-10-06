package ticket

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"
)

// CertificateImage is the uploaded image of a certificate, exactly as received, with the format the
// HTTP layer detected from its content ("" if unknown). It is sent to the verifier unchanged.
type CertificateImage struct {
	Data     []byte
	MimeType string
}

// Ports are what VerifyAndGrant needs from outside: the verifier, the ticket code generator and a logger.
type Ports struct {
	Verifier  Verifier
	Generator *Generator
	Logger    *slog.Logger
}

// acceptedTypes are the formats iPhone and major Android phones produce as-is (business rule).
var acceptedTypes = map[string]bool{
	"image/jpeg": true, "image/png": true, "image/heic": true, "image/heif": true,
	"image/avif": true, "image/webp": true,
}

// VerifyAndGrant verifies a certificate image and grants a new ticket only when it passes: the image
// must be non-empty and in an accepted format, then the verifier must judge it valid. Otherwise it
// returns a business error (ErrEmptyImage, ErrUnsupportedImage, ErrCertificateRejected, or a wrapped
// ErrVerifierTimeout / ErrVerifierUpstream). Shared by the QR inline grant API and the ticket grant API.
func VerifyAndGrant(ctx context.Context, p Ports, img CertificateImage) (Ticket, error) {
	if len(img.Data) == 0 {
		return Ticket{}, ErrEmptyImage
	}
	if !acceptedTypes[img.MimeType] {
		return Ticket{}, ErrUnsupportedImage
	}

	v, err := p.Verifier.Verify(ctx, img)
	switch {
	case errors.Is(err, ErrVerifierTimeout):
		return Ticket{}, err
	case err != nil:
		p.Logger.ErrorContext(ctx, "image analysis failed", "error", err)
		if !errors.Is(err, ErrVerifierUpstream) {
			err = fmt.Errorf("%w: %v", ErrVerifierUpstream, err)
		}
		return Ticket{}, err
	case !v.Valid:
		p.Logger.InfoContext(ctx, "image rejected", "reason", v.Reason)
		return Ticket{}, ErrCertificateRejected
	}

	t, err := p.Generator.Generate()
	if err != nil {
		return Ticket{}, err
	}
	p.Logger.InfoContext(ctx, "ticket issued",
		"ticketCode", t.Code, "issuedAt", t.IssuedAt.Format(time.RFC3339), "analysisReason", v.Reason)
	return t, nil
}
