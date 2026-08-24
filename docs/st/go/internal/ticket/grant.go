package ticket

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"
)

// CertificateImage はアップロードされた証明書の画像で、受け取ったままのデータと、HTTP 層がその内容から
// 判別した形式(不明なら "")を持つ。検証器にはそのまま送られる。
type CertificateImage struct {
	Data     []byte
	MimeType string
}

// Ports は VerifyAndGrant が外部に求めるもの: 検証器、チケットコード生成器、ロガー。
type Ports struct {
	Verifier  Verifier
	Generator *Generator
	Logger    *slog.Logger
}

// acceptedTypes は iPhone と主要な Android 端末がそのまま生成する形式(ビジネスルール)。
var acceptedTypes = map[string]bool{
	"image/jpeg": true, "image/png": true, "image/heic": true, "image/heif": true,
	"image/avif": true, "image/webp": true,
}

// VerifyAndGrant は証明書画像を検証し、合格したときだけ新しいチケットを付与する: 画像が空でなく
// 受け付ける形式であること、そのうえで検証器の結果が PASS であることが条件。そうでなければ
// ビジネスエラー(ErrEmptyImage、ErrUnsupportedImage、REJECT なら ErrCertificateRejected、
// RETRY なら ErrCertificateRetry、またはラップされた ErrVerifierTimeout / ErrVerifierUpstream)を返す。
// QR インライン付与 API とチケット付与 API で共有する。
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
	}
	switch v.Result {
	case ResultPass:
	case ResultReject:
		p.Logger.InfoContext(ctx, "image rejected", "result", v.Result)
		return Ticket{}, ErrCertificateRejected
	case ResultRetry:
		p.Logger.InfoContext(ctx, "image to be taken again", "result", v.Result)
		return Ticket{}, ErrCertificateRetry
	default: // Verifier が返すのは 3 つの結果だけ。それ以外はその実装のバグ
		p.Logger.ErrorContext(ctx, "image analysis failed", "error", "unknown result", "result", v.Result)
		return Ticket{}, fmt.Errorf("%w: unknown result %q", ErrVerifierUpstream, v.Result)
	}

	t, err := p.Generator.Generate()
	if err != nil {
		return Ticket{}, err
	}
	p.Logger.InfoContext(ctx, "ticket issued",
		"ticketCode", t.Code, "issuedAt", t.IssuedAt.Format(time.RFC3339), "result", v.Result)
	return t, nil
}
