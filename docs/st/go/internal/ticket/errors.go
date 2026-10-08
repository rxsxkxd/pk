package ticket

import "errors"

// Business errors of VerifyAndGrant. The HTTP layer maps them to responses (package httpapi); the
// verifier errors (ErrVerifierUpstream, ErrVerifierTimeout) are returned wrapped as well. The messages
// are part of the API responses, so they stay as they were.
var (
	ErrEmptyImage          = errors.New("image is empty")
	ErrUnsupportedImage    = errors.New("image must be JPEG, PNG, HEIC/HEIF, AVIF or WebP")
	ErrCertificateRejected = errors.New("image was rejected")
	ErrCertificateRetry    = errors.New("image could not be verified; take it again")
)
