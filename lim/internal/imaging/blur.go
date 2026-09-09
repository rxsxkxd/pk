// Package imaging はマスキングに必要な画像処理を提供する。
package imaging

import (
	"image"
	"image/draw"
	"math"
)

// ToRGBA は任意の image.Image を *image.RGBA（アルファ乗算済み）へ正規化する。
// CMYK / Paletted / Gray などをまとめて扱えるようにするのが目的。
func ToRGBA(src image.Image) *image.RGBA {
	if rgba, ok := src.(*image.RGBA); ok && rgba.Rect.Min == (image.Point{}) {
		return rgba
	}
	b := src.Bounds()
	dst := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(dst, dst.Bounds(), src, b.Min, draw.Src)
	return dst
}

// BlurRadius はマスク半径を画像の短辺に対する比率から決定する。
//
// 半径を絶対値で固定すると、大きな画像でマスクが実質的に効かなくなる
// （例: 8000px の画像に半径 8px を適用しても文字が読める）。
// 設計書 §12.1 に従い、常に寸法比で算出する。
func BlurRadius(w, h int, ratio, minPx float64) float64 {
	short := float64(w)
	if h < w {
		short = float64(h)
	}
	r := short * ratio
	if r < minPx {
		r = minPx
	}
	return r
}

// GaussianBlur はガウスぼかしを適用する。
//
// sigma が大きい（本用途では 100px 超もあり得る）ため、素朴な畳み込みでは
// 計算量が半径に比例して破綻する。ここでは半径によらず O(pixels) で済む
// ボックスぼかし 3 回の重ね掛けでガウス分布を近似する。視覚的には
// 真のガウスぼかしと区別がつかない。
//
// 入力はアルファ乗算済みの RGBA を前提とする。乗算済みのまま畳み込むことで、
// 透明画素の色が不透明部分へにじみ出すのを防ぐ。
func GaussianBlur(src *image.RGBA, sigma float64) *image.RGBA {
	w, h := src.Rect.Dx(), src.Rect.Dy()
	if w == 0 || h == 0 || sigma <= 0 {
		return src
	}

	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	boxes := boxesForGauss(sigma, 3)

	plane := make([]float32, w*h)
	tmp := make([]float32, w*h)

	// メモリを抑えるためチャンネルごとに処理する。
	for c := 0; c < 4; c++ {
		for i := 0; i < w*h; i++ {
			plane[i] = float32(src.Pix[i*4+c])
		}
		for _, size := range boxes {
			r := (size - 1) / 2
			if r <= 0 {
				continue
			}
			boxBlurH(plane, tmp, w, h, r)
			boxBlurV(tmp, plane, w, h, r)
		}
		for i := 0; i < w*h; i++ {
			v := plane[i] + 0.5
			if v < 0 {
				v = 0
			} else if v > 255 {
				v = 255
			}
			dst.Pix[i*4+c] = uint8(v)
		}
	}
	return dst
}

// boxesForGauss はガウス分布を近似するための各ボックスぼかしの幅を返す。
// 3 回の重ね掛けで標準偏差 sigma に一致するよう幅を決める。
func boxesForGauss(sigma float64, n int) []int {
	wIdeal := math.Sqrt(12*sigma*sigma/float64(n) + 1)
	wl := int(math.Floor(wIdeal))
	if wl%2 == 0 {
		wl--
	}
	if wl < 1 {
		wl = 1
	}
	wu := wl + 2

	mIdeal := (12*sigma*sigma - float64(n*wl*wl) - float64(4*n*wl) - float64(3*n)) /
		(-4*float64(wl) - 4)
	m := int(math.Round(mIdeal))

	sizes := make([]int, n)
	for i := range sizes {
		if i < m {
			sizes[i] = wl
		} else {
			sizes[i] = wu
		}
	}
	return sizes
}

// boxBlurH は水平方向の移動平均。行ごとの累積和を使い、半径によらず O(w) で処理する。
// 端は「窓に入っている画素だけで平均する」方式（実在画素のみを数える）。
func boxBlurH(src, dst []float32, w, h, r int) {
	pre := make([]float64, w+1)
	for y := 0; y < h; y++ {
		row := y * w
		pre[0] = 0
		for x := 0; x < w; x++ {
			pre[x+1] = pre[x] + float64(src[row+x])
		}
		for x := 0; x < w; x++ {
			lo := x - r
			if lo < 0 {
				lo = 0
			}
			hi := x + r
			if hi > w-1 {
				hi = w - 1
			}
			dst[row+x] = float32((pre[hi+1] - pre[lo]) / float64(hi-lo+1))
		}
	}
}

// boxBlurV は垂直方向の移動平均。
func boxBlurV(src, dst []float32, w, h, r int) {
	pre := make([]float64, h+1)
	for x := 0; x < w; x++ {
		pre[0] = 0
		for y := 0; y < h; y++ {
			pre[y+1] = pre[y] + float64(src[y*w+x])
		}
		for y := 0; y < h; y++ {
			lo := y - r
			if lo < 0 {
				lo = 0
			}
			hi := y + r
			if hi > h-1 {
				hi = h - 1
			}
			dst[y*w+x] = float32((pre[hi+1] - pre[lo]) / float64(hi-lo+1))
		}
	}
}

// Downscale は最近傍でない単純な面積平均による縮小。
// 設計書 §12.3 の追加ハードニング用（既定では factor=1 で未使用）。
func Downscale(src *image.RGBA, factor int) *image.RGBA {
	if factor <= 1 {
		return src
	}
	w, h := src.Rect.Dx(), src.Rect.Dy()
	nw, nh := max(1, w/factor), max(1, h/factor)
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		for x := 0; x < nw; x++ {
			var sum [4]int
			var n int
			for sy := y * factor; sy < min((y+1)*factor, h); sy++ {
				for sx := x * factor; sx < min((x+1)*factor, w); sx++ {
					o := sy*src.Stride + sx*4
					for c := 0; c < 4; c++ {
						sum[c] += int(src.Pix[o+c])
					}
					n++
				}
			}
			o := y*dst.Stride + x*4
			for c := 0; c < 4; c++ {
				dst.Pix[o+c] = uint8(sum[c] / n)
			}
		}
	}
	return dst
}

// Upscale は最近傍で元の寸法へ戻す。情報は縮小時に失われているため補間方式は問わない。
func Upscale(src *image.RGBA, w, h int) *image.RGBA {
	sw, sh := src.Rect.Dx(), src.Rect.Dy()
	if sw == w && sh == h {
		return src
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		sy := min(y*sh/h, sh-1)
		for x := 0; x < w; x++ {
			sx := min(x*sw/w, sw-1)
			copy(dst.Pix[y*dst.Stride+x*4:][:4], src.Pix[sy*src.Stride+sx*4:][:4])
		}
	}
	return dst
}

// TopRegion は画像上部の固定マスク領域を返す（ratio=0.5 で上半分）。
// 検出処理を使わず、常にこの矩形だけをマスクする。
func TopRegion(w, h int, ratio float64) image.Rectangle {
	if ratio <= 0 {
		return image.Rectangle{}
	}
	if ratio > 1 {
		ratio = 1
	}
	rh := int(math.Round(float64(h) * ratio))
	if rh < 1 {
		rh = 1
	}
	if rh > h {
		rh = h
	}
	return image.Rect(0, 0, w, rh)
}

// Crop は矩形領域を独立した *image.RGBA として切り出す。
func Crop(src *image.RGBA, r image.Rectangle) *image.RGBA {
	r = r.Intersect(src.Rect)
	dst := image.NewRGBA(image.Rect(0, 0, r.Dx(), r.Dy()))
	for y := 0; y < r.Dy(); y++ {
		copy(dst.Pix[y*dst.Stride:][:dst.Stride],
			src.Pix[(r.Min.Y+y)*src.Stride+r.Min.X*4:][:dst.Stride])
	}
	return dst
}

// Paste は src を dst の at 位置へ貼り戻す。
func Paste(dst, src *image.RGBA, at image.Point) {
	for y := 0; y < src.Rect.Dy(); y++ {
		dy := at.Y + y
		if dy < 0 || dy >= dst.Rect.Dy() {
			continue
		}
		n := min(src.Stride, (dst.Rect.Dx()-at.X)*4)
		if n <= 0 {
			continue
		}
		copy(dst.Pix[dy*dst.Stride+at.X*4:][:n], src.Pix[y*src.Stride:][:n])
	}
}
