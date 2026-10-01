package qr

import (
	"bytes"
	"image"
	_ "image/png"
	"testing"

	"github.com/makiuchi-d/gozxing"
	qrreader "github.com/makiuchi-d/gozxing/qrcode"
)

func TestPNGDecodesToContent(t *testing.T) {
	const code = "20261001-7K3QX9MZ2P"
	data, err := PNG(code)
	if err != nil {
		t.Fatal(err)
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if b := img.Bounds(); b.Dx() != size || b.Dy() != size {
		t.Errorf("size = %v, want %dx%d", b.Size(), size, size)
	}
	bmp, err := gozxing.NewBinaryBitmapFromImage(img)
	if err != nil {
		t.Fatal(err)
	}
	res, err := qrreader.NewQRCodeReader().Decode(bmp, nil)
	if err != nil {
		t.Fatal(err)
	}
	if res.GetText() != code {
		t.Errorf("decoded %q, want %q", res.GetText(), code)
	}
}
