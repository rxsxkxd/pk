// Package imageinput detects the format of an uploaded image. This is a technical concern of the HTTP
// layer; which formats are accepted is a business rule decided in usecase.
package imageinput

import (
	"bytes"
	"image/jpeg"
	"image/png"

	"golang.org/x/image/webp"
)

// MaxBytes is the upload limit set by the runtime: a Lambda request is at most 6MB and API Gateway
// base64-encodes binary bodies (×4/3).
const MaxBytes = 4 << 20

// ISO BMFF major brands (bytes 8-12, after "ftyp") of the HEIF family that phones produce:
// iPhone HEIC (heic/heix), Android HEIF (heic/mif1) and AVIF (avif).
var ftypBrands = map[string]string{
	"heic": "image/heic", "heix": "image/heic", "hevc": "image/heic", "hevx": "image/heic",
	"mif1": "image/heif", "msf1": "image/heif",
	"avif": "image/avif", "avis": "image/avif",
}

// Detect returns the MIME type of data, or "" when it is not a recognizable image. JPEG, PNG and WebP
// headers are parsed up to the image size, so bytes that only start like an image are rejected;
// HEIF/AVIF are recognized by their ftyp brand.
func Detect(data []byte) string {
	r := bytes.NewReader(data)
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xD8, 0xFF}):
		if _, err := jpeg.DecodeConfig(r); err == nil {
			return "image/jpeg"
		}
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		if _, err := png.DecodeConfig(r); err == nil {
			return "image/png"
		}
	case len(data) >= 12 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		if _, err := webp.DecodeConfig(r); err == nil {
			return "image/webp"
		}
	case len(data) >= 12 && string(data[4:8]) == "ftyp":
		return ftypBrands[string(data[8:12])]
	}
	return ""
}
