package imaging

import "image"

// DefaultStrengthBlockPx は強度検査の区画サイズ。
//
// 領域全体の平均で判定すると、小さな素通し部分が広い平坦な背景に埋もれる。
// 引きの人物写真では顔がマスク領域の 1% 未満しかなく、顔がくっきり残っていても
// 平均は低いままで検査を通ってしまう。区画に割って最悪値を見ることで、
// 局所的な素通しが平均に薄められないようにする。
//
// 区画を小さくすると標本数が減り、量子化ノイズを拾った区画が最悪値に選ばれて
// 誤検知が増える。実測では 16px では正常な画像でも最悪値が跳ね、64px では
// 落ち着いた。顔（数十 px）を 1 区画に収められる大きさでもある。
const DefaultStrengthBlockPx = 64

// LaplacianVariance は画像全体のエッジ量の代表値を返す。
func LaplacianVariance(img *image.RGBA) float64 {
	return laplacianVarianceRect(img, img.Bounds())
}

// LaplacianVarianceBlockMax は画像を block 単位の区画に割り、最も
// エッジが残っている区画のスコアを返す（設計書 §12.4）。
//
// 出力前にこの値が十分小さいことを確認することで、マスクの効いていない部分が
// 残ったまま出力される事故を防ぐ。
func LaplacianVarianceBlockMax(img *image.RGBA, block int) float64 {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if block <= 0 || w <= block || h <= block {
		return laplacianVarianceRect(img, b)
	}

	var worst float64
	for y := 0; y < h; y += block {
		// 端は区画がはみ出すので内側へ寄せる。直前の区画と重なるが、
		// 最悪値を取るだけなので二重に数えても問題ない。
		y0 := min(y, h-block) + b.Min.Y
		for x := 0; x < w; x += block {
			x0 := min(x, w-block) + b.Min.X
			v := laplacianVarianceRect(img, image.Rect(x0, y0, x0+block, y0+block))
			if v > worst {
				worst = v
			}
		}
	}
	return worst
}

// laplacianVarianceRect は指定矩形のラプラシアン分散を返す。
//
// 近傍には矩形の外の画素も使う。区画の境目に本物でないエッジが立つのを避けるため。
// 全画素を走査する。格子状に間引く案は測定の上で棄却した。周期的な模様
// （布地・網点など）と標本格子が干渉すると分散を数分の 1 に見積もることがあり、
// これは「マスク不足を見逃す」方向の誤差になる。
func laplacianVarianceRect(img *image.RGBA, r image.Rectangle) float64 {
	b := img.Bounds()
	// 画像の最外周は近傍が取れないため除く。
	r = r.Intersect(image.Rect(b.Min.X+1, b.Min.Y+1, b.Max.X-1, b.Max.Y-1))
	if r.Dx() <= 0 || r.Dy() <= 0 {
		return 0
	}

	var sum, sumSq float64
	n := float64(r.Dx() * r.Dy())

	for y := r.Min.Y; y < r.Max.Y; y++ {
		o := img.PixOffset(r.Min.X, y)
		up := o - img.Stride
		down := o + img.Stride
		for x := r.Min.X; x < r.Max.X; x++ {
			v := float64(lum(img.Pix, up) + lum(img.Pix, down) +
				lum(img.Pix, o-4) + lum(img.Pix, o+4) - 4*lum(img.Pix, o))
			sum += v
			sumSq += v * v
			o += 4
			up += 4
			down += 4
		}
	}
	mean := sum / n
	return sumSq/n - mean*mean
}

// lum は ITU-R BT.601 の輝度。係数を 16bit 固定小数で持ち、float 変換を避ける。
func lum(pix []uint8, o int) int32 {
	const (
		wr = 19595 // 0.299 * 65536
		wg = 38470 // 0.587 * 65536
		wb = 7471  // 0.114 * 65536
	)
	return int32((wr*int(pix[o]) + wg*int(pix[o+1]) + wb*int(pix[o+2])) >> 16)
}
