package ticket

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
)

type stubVerifier struct {
	verdict Verdict
	err     error
}

func (s stubVerifier) Verify(context.Context, CertificateImage) (Verdict, error) {
	return s.verdict, s.err
}

func ports(v Verifier) Ports {
	g, err := NewGenerator("TQR")
	if err != nil {
		panic(err)
	}
	return Ports{Verifier: v, Generator: g, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

// TestVerifyAndGrantErrors: only business errors come back (the HTTP layer maps them).
func TestVerifyAndGrantErrors(t *testing.T) {
	jpeg := CertificateImage{Data: []byte{1}, MimeType: "image/jpeg"}
	tests := []struct {
		name     string
		verifier Verifier
		img      CertificateImage
		want     error
	}{
		{"empty image", stubVerifier{verdict: Verdict{Result: ResultPass}}, CertificateImage{MimeType: "image/jpeg"}, ErrEmptyImage},
		{"unsupported format", stubVerifier{verdict: Verdict{Result: ResultPass}}, CertificateImage{Data: []byte{1}, MimeType: "image/gif"}, ErrUnsupportedImage},
		{"REJECT from the verifier", stubVerifier{verdict: Verdict{Result: ResultReject}}, jpeg, ErrCertificateRejected},
		{"RETRY from the verifier", stubVerifier{verdict: Verdict{Result: ResultRetry}}, jpeg, ErrCertificateRetry},
		{"unknown result counts as upstream", stubVerifier{verdict: Verdict{Result: "MAYBE"}}, jpeg, ErrVerifierUpstream},
		{"verifier timeout", stubVerifier{err: ErrVerifierTimeout}, jpeg, ErrVerifierTimeout},
		{"verifier upstream error", stubVerifier{err: ErrVerifierUpstream}, jpeg, ErrVerifierUpstream},
		{"unexpected verifier error counts as upstream", stubVerifier{err: errors.New("bug")}, jpeg, ErrVerifierUpstream},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := VerifyAndGrant(context.Background(), ports(tt.verifier), tt.img); !errors.Is(err, tt.want) {
				t.Errorf("err = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestVerifyAndGrantValid(t *testing.T) {
	tk, err := VerifyAndGrant(context.Background(), ports(stubVerifier{verdict: Verdict{Result: ResultPass}}),
		CertificateImage{Data: []byte{1}, MimeType: "image/heic"})
	if err != nil || tk.Code == "" {
		t.Fatalf("VerifyAndGrant = %+v, %v", tk, err)
	}
}
