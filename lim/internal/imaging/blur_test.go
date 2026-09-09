package imaging

import (
	"image"
	"image/color"
	"math"
	"testing"
)

func TestBlurRadiusScalesWithImageSize(t *testing.T) {
	// 半径を絶対値で固定すると大きい画像でマスクが効かなくなるため、
	// 寸法比で算出されていることを確認する（設計書 §12.1 の回帰テスト）。
	tests := []struct {
		w, h int
		want float64
	}{
		{4000, 3000, 120},
		{800, 600, 24},
		{200, 150, 8}, // 下限に張り付く
		{100, 100, 8}, // 下限
	}
	for _, tt := range tests {
		if got := BlurRadius(tt.w, tt.h, 0.04, 8); got != tt.want {
			t.Errorf("BlurRadius(%d,%d) = %v, want %v", tt.w, tt.h, got, tt.want)
		}
	}
}

// textLikeImage は文字のような高コントラストの細い縦縞を描いた画像。
func textLikeImage(w, h, strokeWidth int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.RGBA{255, 255, 255, 255}
			if (x/strokeWidth)%2 == 0 {
				c = color.RGBA{0, 0, 0, 255}
			}
			img.Set(x, y, c)
		}
	}
	return img
}

func TestGaussianBlurRemovesFineDetail(t *testing.T) {
	src := textLikeImage(400, 300, 3)
	before := LaplacianVariance(src)

	radius := BlurRadius(400, 300, 0.04, 8) // = 12
	out := GaussianBlur(src, radius)
	after := LaplacianVariance(out)

	if before < 100 {
		t.Fatalf("test fixture is not detailed enough: variance %v", before)
	}
	if after >= 5.0 {
		t.Errorf("blurred image still detailed: variance %v (want < 5.0)", after)
	}
	t.Logf("laplacian variance %.1f -> %.4f", before, after)
}

func TestGaussianBlurPreservesMeanBrightness(t *testing.T) {
	// ぼかしは移動平均の重ね掛けなので、全体の平均輝度は保たれるべき。
	src := textLikeImage(200, 200, 4)
	out := GaussianBlur(src, 10)

	mean := func(img *image.RGBA) float64 {
		var sum float64
		n := img.Rect.Dx() * img.Rect.Dy()
		for i := 0; i < n; i++ {
			sum += float64(img.Pix[i*4])
		}
		return sum / float64(n)
	}
	if diff := math.Abs(mean(src) - mean(out)); diff > 2 {
		t.Errorf("mean brightness drifted by %v", diff)
	}
}

func TestGaussianBlurKeepsOpaqueAlpha(t *testing.T) {
	src := textLikeImage(64, 64, 2)
	out := GaussianBlur(src, 6)
	for i := 0; i < 64*64; i++ {
		if out.Pix[i*4+3] != 255 {
			t.Fatalf("alpha changed at %d: %d", i, out.Pix[i*4+3])
		}
	}
}

func TestApplyOrientationRotates90(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 4, 2))
	src.Set(0, 0, color.RGBA{1, 2, 3, 255}) // 左上に印

	out := ApplyOrientation(src, 6) // 時計回り 90 度
	if w, h := out.Rect.Dx(), out.Rect.Dy(); w != 2 || h != 4 {
		t.Fatalf("size = %dx%d, want 2x4", w, h)
	}
	// 左上の画素は右上へ移動する。
	if r, _, _, _ := out.At(1, 0).RGBA(); r>>8 != 1 {
		t.Errorf("marker pixel not at (1,0): %v", out.At(1, 0))
	}
}

func TestApplyOrientationNoopForUnsetValues(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 3, 2))
	for _, o := range []Orientation{0, 1, 9} {
		if got := ApplyOrientation(src, o); got != src {
			t.Errorf("orientation %d should be a no-op", o)
		}
	}
}

func TestDownscaleThenUpscaleKeepsDimensions(t *testing.T) {
	src := textLikeImage(120, 80, 3)
	small := Downscale(src, 4)
	if w, h := small.Rect.Dx(), small.Rect.Dy(); w != 30 || h != 20 {
		t.Fatalf("downscaled size = %dx%d, want 30x20", w, h)
	}
	back := Upscale(small, 120, 80)
	if w, h := back.Rect.Dx(), back.Rect.Dy(); w != 120 || h != 80 {
		t.Errorf("upscaled size = %dx%d, want 120x80", w, h)
	}
}

func TestTopRegion(t *testing.T) {
	tests := []struct {
		w, h  int
		ratio float64
		wantH int
	}{
		{200, 200, 0.5, 100},
		{200, 101, 0.5, 51}, // 奇数は四捨五入
		{200, 200, 0.25, 50},
		{200, 200, 1.0, 200},
		{200, 200, 2.0, 200}, // 1 を超える指定は 1 に丸める
		{200, 3, 0.1, 1},     // 最低 1px は確保する
	}
	for _, tt := range tests {
		r := TopRegion(tt.w, tt.h, tt.ratio)
		if r.Min != (image.Point{}) {
			t.Errorf("TopRegion(%d,%d,%v).Min = %v, want (0,0)", tt.w, tt.h, tt.ratio, r.Min)
		}
		if r.Dx() != tt.w || r.Dy() != tt.wantH {
			t.Errorf("TopRegion(%d,%d,%v) = %dx%d, want %dx%d",
				tt.w, tt.h, tt.ratio, r.Dx(), r.Dy(), tt.w, tt.wantH)
		}
	}
}

func TestCropAndPasteRoundTrip(t *testing.T) {
	src := textLikeImage(40, 30, 3)
	region := TopRegion(40, 30, 0.5)

	part := Crop(src, region)
	if part.Rect.Dx() != 40 || part.Rect.Dy() != 15 {
		t.Fatalf("cropped size = %dx%d, want 40x15", part.Rect.Dx(), part.Rect.Dy())
	}
	// 切り出した画素が一致する。
	for y := 0; y < 15; y++ {
		for x := 0; x < 40; x++ {
			if part.RGBAAt(x, y) != src.RGBAAt(x, y) {
				t.Fatalf("crop mismatch at (%d,%d)", x, y)
			}
		}
	}

	// 貼り戻すと領域外は変化しない。
	dst := textLikeImage(40, 30, 3)
	filled := image.NewRGBA(image.Rect(0, 0, 40, 15))
	for i := range filled.Pix {
		filled.Pix[i] = 0x77
	}
	Paste(dst, filled, region.Min)

	for y := 0; y < 15; y++ {
		if dst.RGBAAt(0, y) != (color.RGBA{0x77, 0x77, 0x77, 0x77}) {
			t.Fatalf("paste did not apply at row %d: %v", y, dst.RGBAAt(0, y))
		}
	}
	for y := 15; y < 30; y++ {
		if dst.RGBAAt(0, y) != src.RGBAAt(0, y) {
			t.Fatalf("paste leaked into row %d", y)
		}
	}
}
