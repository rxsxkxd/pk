package imaging

import "image"

// LaplacianVariance は画像のエッジ量の代表値を返す。
//
// 出力側でこの値が十分小さいことを確認することで、「パラメータ設定ミスなどで
// 実質マスクされていない画像が出力される」事故を機械的に防ぐ（設計書 §12.4）。
// ぼけた画像ほど値が小さくなる。
//
// 全画素を走査する。格子状に間引く案は測定の上で棄却した。周期的な模様
// （布地・網点など）と標本格子が干渉すると分散を数分の 1 に見積もることがあり、
// これは「マスク不足を見逃す」方向の誤差になる。数 ms のために負うリスクではない。
// 代わりに輝度計算を整数で行い、中間バッファの確保をなくしてある。
func LaplacianVariance(img *image.RGBA) float64 {
	w, h := img.Rect.Dx(), img.Rect.Dy()
	if w < 3 || h < 3 {
		return 0
	}

	var sum, sumSq float64
	n := float64((w - 2) * (h - 2))

	for y := 1; y < h-1; y++ {
		o := y*img.Stride + 4 // x = 1
		up := o - img.Stride
		down := o + img.Stride
		for x := 1; x < w-1; x++ {
			v := float64(lum(img.Pix, up) + lum(img.Pix, down) +
				lum(img.Pix, o-4) + lum(img.Pix, o+4) - 4*lum(img.Pix, o))
			sum += v
			sumSq += v * v
			o += 4
			up += 4
			down += 4
		}
	}
	if n == 0 {
		return 0
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
