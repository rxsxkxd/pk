// Package imageinput validates uploaded images before they are sent for analysis.
package imageinput

import (
	"bytes"
	"fmt"

	"ticketqr/go/internal/apperr"
)

const MaxBytes = 4 << 20

// ISO BMFF major brands (bytes 8-12, after "ftyp") of the HEIF family that phones produce:
// iPhone HEIC (heic/heix), Android HEIF (heic/mif1) and AVIF (avif).
var ftypBrands = map[string]string{
	"heic": "image/heic", "heix": "image/heic", "hevc": "image/heic", "hevx": "image/heic",
	"mif1": "image/heif", "msf1": "image/heif",
	"avif": "image/avif", "avis": "image/avif",
}

// Validate checks size and format and returns the detected MIME type. Accepted formats are what iPhone
// and major Android phones upload as-is: JPEG, PNG, HEIC/HEIF, AVIF and WebP. Detection reads the file
// header only (the Node version parses further with image-size).
func Validate(data []byte) (string, error) {
	if len(data) == 0 {
		return "", apperr.BadRequest("image is empty")
	}
	if len(data) > MaxBytes {
		return "", apperr.PayloadTooLarge(fmt.Sprintf("image must be %d bytes or less", MaxBytes))
	}
	if mime := detect(data); mime != "" {
		return mime, nil
	}
	return "", apperr.UnsupportedMediaType("image must be JPEG, PNG, HEIC/HEIF, AVIF or WebP")
}

func detect(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xD8, 0xFF}):
		return "image/jpeg"
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return "image/png"
	case len(data) >= 12 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return "image/webp"
	case len(data) >= 12 && string(data[4:8]) == "ftyp":
		return ftypBrands[string(data[8:12])]
	}
	return ""
}
