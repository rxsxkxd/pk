// Package qr renders ticket codes as QR PNG images.
package qr

import qrcode "github.com/skip2/go-qrcode"

const size = 256

// PNG renders content with error correction level M and a 4-module quiet zone (library default).
func PNG(content string) ([]byte, error) {
	return qrcode.Encode(content, qrcode.Medium, size)
}
