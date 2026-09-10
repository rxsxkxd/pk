package masking

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/png"
	"testing"

	"github.com/rxsxkxd/lim/internal/imaging"
)

func defaults() Options {
	return Options{
		MaskHeightRatio: 0.5,
		BlurRatio:       0.04,
		MinBlurRadiusPx: 8,
		DownscaleFactor: 1,
		MaxLaplacianVar: 5.0,
		MaxPixels:       64_000_000,
		JPEGQuality:     85,
	}
}

func stripesPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.RGBA{255, 255, 255, 255}
			if (x/3)%2 == 0 {
				c = color.RGBA{10, 10, 10, 255}
			}
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func decode(t *testing.T, b []byte) *image.RGBA {
	t.Helper()
	img, _, err := image.Decode(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	return imaging.ToRGBA(img)
}

func TestApplyMasksTopHalfOnly(t *testing.T) {
	raw := stripesPNG(t, 200, 200)
	res, err := Apply(raw, defaults())
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if res.Region != "top 50% (0,0,200,100)" {
		t.Errorf("Region = %q", res.Region)
	}
	if res.RadiusPx != 8 {
		t.Errorf("RadiusPx = %v, want 8", res.RadiusPx)
	}

	src, out := decode(t, raw), decode(t, res.Body)
	for y := 100; y < 200; y++ {
		for x := 0; x < 200; x++ {
			if src.RGBAAt(x, y) != out.RGBAAt(x, y) {
				t.Fatalf("bottom half modified at (%d,%d)", x, y)
			}
		}
	}
	if v := imaging.LaplacianVariance(imaging.Crop(out, image.Rect(0, 0, 200, 100))); v >= 5.0 {
		t.Errorf("top half variance = %v, want < 5.0", v)
	}
}

func TestApplyReturnsNothingWhenMaskIsWeak(t *testing.T) {
	// 強度検証に落ちたときは Result を返さない。呼び出し側が誤って
	// 未マスクの画像を書き出せないようにするための契約。
	o := defaults()
	o.BlurRatio = 0.0001
	o.MinBlurRadiusPx = 0.1

	res, err := Apply(stripesPNG(t, 200, 200), o)
	if res != nil {
		t.Error("Result must be nil when the strength check fails")
	}
	var se *StrengthError
	if !errors.As(err, &se) {
		t.Fatalf("error = %v, want StrengthError", err)
	}
	if se.Score <= se.Limit {
		t.Errorf("score %v should exceed limit %v", se.Score, se.Limit)
	}
}

func TestApplyRejectsBadInput(t *testing.T) {
	tests := []struct {
		name string
		raw  []byte
		opts func(*Options)
	}{
		{name: "not an image", raw: []byte("%PDF-1.7")},
		{name: "empty", raw: nil},
		{
			name: "exceeds pixel limit",
			raw:  stripesPNG(t, 100, 100),
			opts: func(o *Options) { o.MaxPixels = 100 },
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			o := defaults()
			if tt.opts != nil {
				tt.opts(&o)
			}
			_, err := Apply(tt.raw, o)
			var ve *ValidationError
			if !errors.As(err, &ve) {
				t.Errorf("error = %v, want ValidationError", err)
			}
		})
	}
}

func TestApplyKeepsDimensionsAndFormat(t *testing.T) {
	raw := stripesPNG(t, 321, 217)
	res, err := Apply(raw, defaults())
	if err != nil {
		t.Fatal(err)
	}
	if res.Format != "png" || res.ContentType != "image/png" {
		t.Errorf("format = %q, contentType = %q", res.Format, res.ContentType)
	}
	out := decode(t, res.Body)
	if w, h := out.Rect.Dx(), out.Rect.Dy(); w != 321 || h != 217 {
		t.Errorf("size = %dx%d, want 321x217", w, h)
	}
}
