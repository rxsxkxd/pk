package imageinput

import (
	"os"
	"testing"
)

func TestDetectSharedImages(t *testing.T) {
	// Real 32x32 images in each format phones upload, shared with the Node version.
	for file, want := range map[string]string{
		"photo.jpg":       "image/jpeg",
		"photo.png":       "image/png",
		"photo.heic":      "image/heic",
		"photo-mif1.heif": "image/heif",
		"photo.avif":      "image/avif",
		"photo.webp":      "image/webp",
	} {
		t.Run(file, func(t *testing.T) {
			data, err := os.ReadFile("../../../testdata/images/" + file)
			if err != nil {
				t.Fatal(err)
			}
			if got := Detect(data); got != want {
				t.Errorf("Detect = %q, want %q", got, want)
			}
		})
	}
}

func TestDetectUnknown(t *testing.T) {
	text, err := os.ReadFile("../../../testdata/images/not-image.txt")
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		"text":                     text,
		"empty":                    {},
		"JPEG magic bytes only":    {0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F'},
		"PNG signature only":       []byte("\x89PNG\r\n\x1a\n\x00\x00"),
		"RIFF but not WebP":        []byte("RIFF\x10\x00\x00\x00WAVEfmt "),
		"WebP header without data": []byte("RIFF\x04\x00\x00\x00WEBP"),
		"unknown ftyp brand":       []byte("\x00\x00\x00\x18ftypisom\x00\x00\x00\x00"),
	} {
		t.Run(name, func(t *testing.T) {
			if got := Detect(data); got != "" {
				t.Errorf("Detect = %q, want unknown", got)
			}
		})
	}
}
