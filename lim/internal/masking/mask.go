// Package masking は画像のマスキング処理そのものを扱う。
//
// S3 や Lambda に依存しないため、Lambda ハンドラとローカル CLI の
// 両方から同じコードを使える。しきい値の調整や目視確認は
// cmd/maskfile 経由でこのパッケージを直接叩いて行う。
package masking

import (
	"bytes"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"

	"github.com/rxsxkxd/lim/internal/imaging"
)

// Options はマスク強度を決める設定。
// すべてサーバー側（呼び出し側）で決まる値であり、画像の投入者は指定できない。
type Options struct {
	MaskHeightRatio float64 // 上部からマスクする高さの比率（0.5 = 上半分）
	BlurRatio       float64 // 短辺に対するぼかし半径の比率
	MinBlurRadiusPx float64 // 半径の絶対下限
	DownscaleFactor int     // 追加ハードニング。1 で無効
	MaxLaplacianVar float64 // 強度検証の上限
	MaxPixels       int64   // decompression bomb 対策
	JPEGQuality     int
}

// Result はマスキング結果。
type Result struct {
	Body        []byte
	ContentType string
	Format      string
	Region      string  // 監査用の領域表記
	RadiusPx    float64 // 実際に適用した半径
	Score       float64 // マスク領域のラプラシアン分散
	Width       int
	Height      int
}

// ValidationError はリトライしても解消しない恒久的な入力エラー。
// 取りこぼしを避けるため成功扱いにはせず、そのまま DLQ へ送る（設計書 §10.1）。
type ValidationError struct{ Reason string }

func (e *ValidationError) Error() string { return "validation: " + e.Reason }

func invalid(format string, a ...any) error {
	return &ValidationError{Reason: fmt.Sprintf(format, a...)}
}

// StrengthError はマスク強度の自己検証に失敗した場合のエラー（設計書 §12.4）。
// このエラーが返った場合、呼び出し側は結果を一切出力してはならない。
type StrengthError struct {
	Score float64
	Limit float64
}

func (e *StrengthError) Error() string {
	return fmt.Sprintf("mask strength check failed: laplacian variance %.3f > %.3f", e.Score, e.Limit)
}

// Apply は画像の上部固定矩形にガウスぼかしを適用し、エンコードして返す。
//
// 強度検証に落ちた場合は StrengthError を返し、Result は返さない。
// 呼び出し側はこの場合に出力を書いてはならない（fail-closed、設計書 §10.4）。
func Apply(raw []byte, o Options) (*Result, error) {
	// 全体をデコードする前に寸法だけ確認し、decompression bomb を弾く。
	cfg, format, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return nil, invalid("cannot decode image header: %v", err)
	}
	if format != "jpeg" && format != "png" {
		return nil, invalid("unsupported format %q (jpeg/png only)", format)
	}
	if int64(cfg.Width)*int64(cfg.Height) > o.MaxPixels {
		return nil, invalid("image %dx%d exceeds pixel limit %d", cfg.Width, cfg.Height, o.MaxPixels)
	}

	decoded, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, invalid("cannot decode image: %v", err)
	}

	img := imaging.ToRGBA(decoded)
	if format == "jpeg" {
		// 出力ではメタデータを引き継がないため、向きは画素へ反映しておく。
		img = imaging.ApplyOrientation(img, imaging.JPEGOrientation(raw))
	}

	w, h := img.Rect.Dx(), img.Rect.Dy()
	// 半径は画像全体の短辺から決める。隠したい特徴（文字の線幅など）の大きさは
	// 領域の高さではなく画像の解像度に比例するため。
	radius := imaging.BlurRadius(w, h, o.BlurRatio, o.MinBlurRadiusPx)

	// 検出処理は使わず、画像上部の固定矩形だけをマスクする。
	region := imaging.TopRegion(w, h, o.MaskHeightRatio)
	part := imaging.Crop(img, region)

	// 領域だけを切り出してぼかすことで、マスク対象の情報が
	// 境界をまたいで非マスク領域へにじみ出すのを防ぐ。
	// 既定では factor=1 で素通り。強度を上げる必要が出たら設定だけで切り替える。
	if f := o.DownscaleFactor; f > 1 {
		small := imaging.Downscale(part, f)
		small = imaging.GaussianBlur(small, radius/float64(f))
		part = imaging.Upscale(small, region.Dx(), region.Dy())
	} else {
		part = imaging.GaussianBlur(part, radius)
	}
	imaging.Paste(img, part, region.Min)

	// 強度検証は「マスクした領域だけ」を対象にする。
	// 画像全体で測ると、非マスク領域の鮮明さに引きずられて必ず不合格になる。
	score := imaging.LaplacianVariance(part)
	if score > o.MaxLaplacianVar {
		return nil, &StrengthError{Score: score, Limit: o.MaxLaplacianVar}
	}

	// Go の標準エンコーダは EXIF / XMP / 埋め込みサムネイルを一切書き出さない。
	// これにより FR-9（メタデータ完全除去）が構造的に満たされる。
	var buf bytes.Buffer
	switch format {
	case "jpeg":
		err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: o.JPEGQuality})
	case "png":
		enc := png.Encoder{CompressionLevel: png.DefaultCompression}
		err = enc.Encode(&buf, img)
	}
	if err != nil {
		return nil, fmt.Errorf("encode output: %w", err)
	}

	return &Result{
		Body:        buf.Bytes(),
		ContentType: "image/" + format,
		Format:      format,
		Region:      fmt.Sprintf("top %.0f%% (0,0,%d,%d)", o.MaskHeightRatio*100, region.Dx(), region.Dy()),
		RadiusPx:    radius,
		Score:       score,
		Width:       w,
		Height:      h,
	}, nil
}
