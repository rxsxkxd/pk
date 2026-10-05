package imageinput

import (
	"os"
	"testing"
)

func TestValidateSharedImages(t *testing.T) {
	// Real 32x32 images in each accepted format, shared with the Node version.
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
			got, err := Validate(data)
			if err != nil || got != want {
				t.Errorf("Validate = %q, %v; want %q", got, err, want)
			}
		})
	}
}

func TestValidateRejects(t *testing.T) {
	text, err := os.ReadFile("../../../testdata/images/not-image.txt")
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		"text":              text,
		"unknown ftyp":      []byte("\x00\x00\x00\x18ftypisom\x00\x00\x00\x00"),
		"RIFF but not WebP": []byte("RIFF\x10\x00\x00\x00WAVEfmt "),
		"empty":             {},
		"too large":         append([]byte{0xFF, 0xD8, 0xFF}, make([]byte, MaxBytes)...),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Validate(data); err == nil {
				t.Error("expected an error")
			}
		})
	}
}
