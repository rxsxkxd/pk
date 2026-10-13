package ticket

import "errors"

// VerifyAndGrant のビジネスエラー。HTTP 層がこれらをレスポンスに対応付ける(package httpapi)。
// 検証器のエラー(ErrVerifierUpstream、ErrVerifierTimeout)もラップして返される。メッセージは
// API レスポンスの一部なので、元のまま変えない。
var (
	ErrEmptyImage          = errors.New("image is empty")
	ErrUnsupportedImage    = errors.New("image must be JPEG, PNG, HEIC/HEIF, AVIF or WebP")
	ErrCertificateRejected = errors.New("image was rejected")
	ErrCertificateRetry    = errors.New("image could not be verified; take it again")
)
