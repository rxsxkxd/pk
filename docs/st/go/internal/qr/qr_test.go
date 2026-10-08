package qr

import (
	"bytes"
	"image"
	"image/color"
	_ "image/png"
	"strings"
	"testing"

	"github.com/makiuchi-d/gozxing"
	qrreader "github.com/makiuchi-d/gozxing/qrcode"
)

func TestPNGDecodesToContent(t *testing.T) {
	for _, content := range []string{
		"202610011943003f2b9c1e8a4d4f6b8e0c7a1d2b3c4d5eTQR",
		"20261231235959ffffffffffff4fffbfffffffffffffffSTAGEFIXEDSUFFIX0123456789abcdef",
		strings.Repeat("x", 120), // larger version, smaller modules
	} {
		t.Run(content, func(t *testing.T) {
			data, err := PNG(content)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")) {
				t.Fatal("output is not PNG")
			}
			img, _, err := image.Decode(bytes.NewReader(data))
			if err != nil {
				t.Fatal(err)
			}
			if b := img.Bounds(); b.Dx() != size || b.Dy() != size {
				t.Errorf("size = %v, want %dx%d", b.Size(), size, size)
			}
			if !isWhite(img.At(0, 0)) || !isWhite(img.At(size-1, size-1)) {
				t.Error("corners must be quiet zone (white)")
			}

			bmp, err := gozxing.NewBinaryBitmapFromImage(img)
			if err != nil {
				t.Fatal(err)
			}
			res, err := qrreader.NewQRCodeReader().Decode(bmp, nil)
			if err != nil {
				t.Fatal(err)
			}
			if res.GetText() != content {
				t.Errorf("decoded %q, want %q", res.GetText(), content)
			}
		})
	}
}

func TestPNGTooLong(t *testing.T) {
	if _, err := PNG(strings.Repeat("x", 3000)); err == nil { // exceeds QR capacity at level M
		t.Fatal("expected error for content beyond QR capacity")
	}
}

func isWhite(c color.Color) bool {
	r, g, b, _ := c.RGBA()
	return r == 0xffff && g == 0xffff && b == 0xffff
}
