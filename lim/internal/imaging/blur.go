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

// DefaultBlurPasses はガウス近似に使うボックスぼかしの回数の既定値。
//
// 1 回 = 単純な移動平均、2 回 = 三角窓、3 回でほぼガウス分布。
// マスキングに必要なのは「情報を落とすこと」であって滑らかさではないため、
// 回数を減らして処理時間を削れる。ただし 1 回は避ける（下の注記）。
const DefaultBlurPasses = 2

// GaussianBlur はガウスぼかしを適用する（既定のパス数）。
func GaussianBlur(src *image.RGBA, sigma float64) *image.RGBA {
	return GaussianBlurPasses(src, sigma, DefaultBlurPasses)
}

// GaussianBlurPasses はパス数を指定してぼかしを適用する。
//
// sigma が大きい（本用途では 100px 超もあり得る）ため、素朴な畳み込みでは
// 計算量が半径に比例して破綻する。ここでは半径によらず O(pixels) で済む
// ボックスぼかしの重ね掛けでガウス分布を近似する。
//
// passes を減らすと処理時間はほぼ比例して減る。仕上がりの滑らかさは落ちるが、
// マスキングの目的（情報を落とすこと）には影響しない。
//
// ただし passes=1（単純な移動平均）は避けたほうがよい。ボックス窓の
// 周波数応答は sinc 状でゼロ点と副ローブを持つため、特定の空間周波数の
// 成分が減衰しきらずに残る。2 回重ねると副ローブが二乗されて十分小さくなる。
//
// 入力はアルファ乗算済みの RGBA を前提とする。乗算済みのまま畳み込むことで、
// 透明画素の色が不透明部分へにじみ出すのを防ぐ。
func GaussianBlurPasses(src *image.RGBA, sigma float64, passes int) *image.RGBA {
	w, h := src.Rect.Dx(), src.Rect.Dy()
	if w == 0 || h == 0 || sigma <= 0 {
		return src
	}
	if passes < 1 {
		passes = 1
	}

	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	boxes := boxesForGauss(sigma, passes)

	// 不透明な画像ではアルファを畳み込む必要がない。JPEG は常にこちらで、
	// 処理するチャンネルが 4 → 3 になる。
	channels := 4
	opaque := src.Opaque()
	if opaque {
		channels = 3
	}

	// 8bit のまま扱う。float に展開すると変換の手間とメモリ帯域が 4 倍になる。
	plane := make([]uint8, w*h)
	tmp := make([]uint8, w*h)
	colSum := make([]int32, w)

	for c := 0; c < channels; c++ {
		for y := 0; y < h; y++ {
			so, ro := y*src.Stride, y*w
			for x := 0; x < w; x++ {
				plane[ro+x] = src.Pix[so+x*4+c]
			}
		}
		for _, size := range boxes {
			r := (size - 1) / 2
			if r <= 0 {
				continue
			}
			boxBlurH(plane, tmp, w, h, r)
			boxBlurV(tmp, plane, w, h, r, colSum)
		}
		for y := 0; y < h; y++ {
			do, ro := y*dst.Stride, y*w
			for x := 0; x < w; x++ {
				dst.Pix[do+x*4+c] = plane[ro+x]
			}
		}
	}

	if opaque {
		for i := 3; i < len(dst.Pix); i += 4 {
			dst.Pix[i] = 0xff
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

// boxBlurH は水平方向の移動平均。
//
// 窓を 1 画素ずつずらしながら、入ってきた画素を足して出ていった画素を引く。
// 累積和の配列を作らずに済み、半径によらず 1 画素あたり定数時間で処理できる。
// 端は窓に入っている実在画素だけで平均する。
func boxBlurH(src, dst []uint8, w, h, r int) {
	for y := 0; y < h; y++ {
		row := y * w

		hi := min(r, w-1)
		var sum int32
		for x := 0; x <= hi; x++ {
			sum += int32(src[row+x])
		}
		cnt := int32(hi + 1)

		for x := 0; x < w; x++ {
			dst[row+x] = uint8((sum + cnt/2) / cnt)
			if add := x + r + 1; add < w {
				sum += int32(src[row+add])
				cnt++
			}
			if del := x - r; del >= 0 {
				sum -= int32(src[row+del])
				cnt--
			}
		}
	}
}

// boxBlurV は垂直方向の移動平均。
//
// 列ごとに走査するとキャッシュミスだらけになるため、列の合計を保持したまま
// 行を上から下へ舐める。読み出しが常に連続アドレスになる。
// colSum は呼び出し側から渡す作業領域（長さ w）。
func boxBlurV(src, dst []uint8, w, h, r int, colSum []int32) {
	clear(colSum)

	hi := min(r, h-1)
	for y := 0; y <= hi; y++ {
		row := y * w
		for x := 0; x < w; x++ {
			colSum[x] += int32(src[row+x])
		}
	}
	cnt := int32(hi + 1)

	for y := 0; y < h; y++ {
		row := y * w
		half := cnt / 2
		for x := 0; x < w; x++ {
			dst[row+x] = uint8((colSum[x] + half) / cnt)
		}
		if add := y + r + 1; add < h {
			ro := add * w
			for x := 0; x < w; x++ {
				colSum[x] += int32(src[ro+x])
			}
			cnt++
		}
		if del := y - r; del >= 0 {
			ro := del * w
			for x := 0; x < w; x++ {
				colSum[x] -= int32(src[ro+x])
			}
			cnt--
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
