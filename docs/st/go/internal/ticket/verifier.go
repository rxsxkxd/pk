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

// Result is the verifier's judgment: the "result" of the image analysis server's response. The API
// looks at nothing else in the response.
type Result string

const (
	ResultPass   Result = "PASS"   // grant a ticket
	ResultReject Result = "REJECT" // not a usable certificate image: ErrCertificateRejected
	ResultRetry  Result = "RETRY"  // could not judge this image; take it again: ErrCertificateRetry
)

// Verdict is the verifier's answer.
type Verdict struct {
	Result Result
}

// Errors a Verifier wraps so VerifyAndGrant can tell a timeout from other failures.
var (
	ErrVerifierUpstream = errors.New("verifier upstream error")
	ErrVerifierTimeout  = errors.New("verifier timeout")
)
