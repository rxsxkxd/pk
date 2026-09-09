package imaging

import "image"

// LaplacianVariance は画像のエッジ量の代表値を返す。
//
// 出力側でこの値が十分小さいことを確認することで、「パラメータ設定ミスなどで
// 実質マスクされていない画像が出力される」事故を機械的に防ぐ（設計書 §12.4）。
// ぼけた画像ほど値が小さくなる。
func LaplacianVariance(img *image.RGBA) float64 {
	w, h := img.Rect.Dx(), img.Rect.Dy()
	if w < 3 || h < 3 {
		return 0
	}

	gray := make([]float64, w*h)
	for i := 0; i < w*h; i++ {
		o := i * 4
		// ITU-R BT.601 の輝度係数
		gray[i] = 0.299*float64(img.Pix[o]) + 0.587*float64(img.Pix[o+1]) + 0.114*float64(img.Pix[o+2])
	}

	var sum, sumSq float64
	var n float64
	for y := 1; y < h-1; y++ {
		for x := 1; x < w-1; x++ {
			i := y*w + x
			// 4 近傍ラプラシアン
			v := gray[i-w] + gray[i+w] + gray[i-1] + gray[i+1] - 4*gray[i]
			sum += v
			sumSq += v * v
			n++
		}
	}
	if n == 0 {
		return 0
	}
	mean := sum / n
	return sumSq/n - mean*mean
}
