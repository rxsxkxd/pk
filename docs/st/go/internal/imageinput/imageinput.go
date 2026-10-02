// Package imageinput validates uploaded images before they are sent for analysis.
package imageinput

import (
	"bytes"
	"fmt"

	"ticketqr/go/internal/apperr"
)

const MaxBytes = 4 << 20

var signatures = []struct {
	mime  string
	magic []byte
}{
	{"image/jpeg", []byte{0xFF, 0xD8, 0xFF}},
	{"image/png", []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}},
}

// Validate checks size and format by magic bytes and returns the detected MIME type.
func Validate(data []byte) (string, error) {
	if len(data) == 0 {
		return "", apperr.BadRequest("image is empty")
	}
	if len(data) > MaxBytes {
		return "", apperr.PayloadTooLarge(fmt.Sprintf("image must be %d bytes or less", MaxBytes))
	}
	for _, s := range signatures {
		if bytes.HasPrefix(data, s.magic) {
			return s.mime, nil
		}
	}
	return "", apperr.UnsupportedMediaType("image must be JPEG or PNG")
}
