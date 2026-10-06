package ticket

import (
	"context"
	"errors"
)

// Verifier asks the verification server whether a certificate image is genuine and acceptable.
// Defined here, where it is used; implemented by package analyzer (an in-process mock and the HTTP
// client of the image analysis server).
type Verifier interface {
	Verify(ctx context.Context, img CertificateImage) (Verdict, error)
}

// Verdict is the verifier's answer.
type Verdict struct {
	Valid  bool
	Reason string
}

// Errors a Verifier wraps so VerifyAndGrant can tell a timeout from other failures.
var (
	ErrVerifierUpstream = errors.New("verifier upstream error")
	ErrVerifierTimeout  = errors.New("verifier timeout")
)
