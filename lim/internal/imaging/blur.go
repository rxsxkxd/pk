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

// Upscale は線形補間で元の寸法へ戻す。
//
// 最近傍で戻すと factor 画素ごとに階段状の段差が立つ。情報は縮小時に失われて
// いるので安全性は変わらないが、この段差を強度検査がエッジとして拾ってしまい、
// 十分にマスクされた画像が不合格になる（設計書 §12.4 の誤検知）。
// 補間して段差を作らないことで、検査が実態を測るようになる。
func Upscale(src *image.RGBA, w, h int) *image.RGBA {
	sw, sh := src.Rect.Dx(), src.Rect.Dy()
	if sw == w && sh == h {
		return src
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	if sw == 0 || sh == 0 {
		return dst
	}

	// 横方向の写像は行ごとに同じなので、先に一度だけ求めておく。
	// 画素ごとに浮動小数で計算し直すと補間のコストが跳ね上がる。
	const fixed = 1 << 12
	sxIdx := make([]int, w)
	sxW := make([]int, w)
	for x := 0; x < w; x++ {
		fx := (float64(x)+0.5)*float64(sw)/float64(w) - 0.5
		sxIdx[x], sxW[x] = interpolationWeights(fx, sw, fixed)
	}

	// 不透明ならアルファは補間せず埋めるだけでよい。
	channels := 4
	opaque := src.Opaque()
	if opaque {
		channels = 3
	}

	for y := 0; y < h; y++ {
		fy := (float64(y)+0.5)*float64(sh)/float64(h) - 0.5
		sy0, wy := interpolationWeights(fy, sh, fixed)
		sy1 := min(sy0+1, sh-1)
		rowTop, rowBot := sy0*src.Stride, sy1*src.Stride
		do := y * dst.Stride

		for x := 0; x < w; x++ {
			sx0 := sxIdx[x]
			wx := sxW[x]
			sx1 := min(sx0+1, sw-1)
			o00, o01 := rowTop+sx0*4, rowTop+sx1*4
			o10, o11 := rowBot+sx0*4, rowBot+sx1*4

			for c := 0; c < channels; c++ {
				top := int(src.Pix[o00+c])*(fixed-wx) + int(src.Pix[o01+c])*wx
				bot := int(src.Pix[o10+c])*(fixed-wx) + int(src.Pix[o11+c])*wx
				dst.Pix[do+c] = uint8((top*(fixed-wy) + bot*wy + fixed*fixed/2) / (fixed * fixed))
			}
			do += 4
		}
	}

	if opaque {
		for i := 3; i < len(dst.Pix); i += 4 {
			dst.Pix[i] = 0xff
		}
	}
	return dst
}

// interpolationWeights は補間元の画素位置と、その隣との混合比（固定小数）を返す。
func interpolationWeights(f float64, size, fixed int) (idx, weight int) {
	if f < 0 {
		return 0, 0
	}
	i := int(f)
	if i >= size-1 {
		return size - 1, 0
	}
	return i, int((f - float64(i)) * float64(fixed))
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
