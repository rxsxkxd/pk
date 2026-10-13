package httpapi

import (
	"errors"
	"net/http"

	"ticketqr/internal/ticket"
)

// apiError は API のエラーレスポンス: HTTP ステータス、エラーコード、メッセージ。
type apiError struct {
	Status  int
	Code    string
	Message string
}

func (e *apiError) Error() string { return e.Code + ": " + e.Message }

func badRequest(msg string) *apiError {
	return &apiError{http.StatusBadRequest, "BAD_REQUEST", msg}
}

func forbidden() *apiError {
	return &apiError{http.StatusForbidden, "FORBIDDEN", "invalid signature"}
}

func payloadTooLarge(msg string) *apiError {
	return &apiError{http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", msg}
}

func unsupportedMediaType(msg string) *apiError {
	return &apiError{http.StatusUnsupportedMediaType, "UNSUPPORTED_MEDIA_TYPE", msg}
}

func notFound() *apiError {
	return &apiError{http.StatusNotFound, "NOT_FOUND", "route not found"}
}

func internalError() *apiError {
	return &apiError{http.StatusInternalServerError, "INTERNAL_ERROR", "internal error"}
}

// toAPIError はあらゆるエラーをエラーレスポンスに変換する: このパッケージのエラーはそのまま、package ticket の
// ビジネスエラーは下の表で、それ以外は INTERNAL_ERROR とする。
func toAPIError(err error) *apiError {
	var e *apiError
	switch {
	case errors.As(err, &e):
		return e
	case errors.Is(err, ticket.ErrEmptyImage):
		return badRequest(ticket.ErrEmptyImage.Error())
	case errors.Is(err, ticket.ErrUnsupportedImage):
		return unsupportedMediaType(ticket.ErrUnsupportedImage.Error())
	case errors.Is(err, ticket.ErrCertificateRejected): // 結果 REJECT
		return &apiError{http.StatusUnprocessableEntity, "IMAGE_REJECTED", ticket.ErrCertificateRejected.Error()}
	case errors.Is(err, ticket.ErrCertificateRetry): // 結果 RETRY
		return &apiError{http.StatusUnprocessableEntity, "IMAGE_RETRY", ticket.ErrCertificateRetry.Error()}
	case errors.Is(err, ticket.ErrVerifierTimeout):
		return &apiError{http.StatusGatewayTimeout, "ANALYSIS_TIMEOUT", "image analysis timed out"}
	case errors.Is(err, ticket.ErrVerifierUpstream):
		return &apiError{http.StatusBadGateway, "ANALYSIS_UPSTREAM_ERROR", "image analysis failed"}
	default:
		return internalError()
	}
}
