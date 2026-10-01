// Package apperr defines errors that map directly to API error responses.
package apperr

import (
	"errors"
	"net/http"
)

type Error struct {
	Status  int
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func BadRequest(msg string) *Error {
	return &Error{http.StatusBadRequest, "BAD_REQUEST", msg}
}

func Forbidden() *Error {
	return &Error{http.StatusForbidden, "FORBIDDEN", "invalid signature"}
}

func PayloadTooLarge(msg string) *Error {
	return &Error{http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", msg}
}

func UnsupportedMediaType(msg string) *Error {
	return &Error{http.StatusUnsupportedMediaType, "UNSUPPORTED_MEDIA_TYPE", msg}
}

func ImageInvalid(reason string) *Error {
	return &Error{http.StatusUnprocessableEntity, "IMAGE_INVALID", reason}
}

func AnalysisUpstream() *Error {
	return &Error{http.StatusBadGateway, "ANALYSIS_UPSTREAM_ERROR", "image analysis failed"}
}

func AnalysisTimeout() *Error {
	return &Error{http.StatusGatewayTimeout, "ANALYSIS_TIMEOUT", "image analysis timed out"}
}

func Internal() *Error {
	return &Error{http.StatusInternalServerError, "INTERNAL_ERROR", "internal error"}
}

// From returns err as *Error, or INTERNAL_ERROR when it is not an application error.
func From(err error) *Error {
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	return Internal()
}
