// Package config は Lambda の環境変数を読み込む。
package config

import (
	"fmt"
	"os"
	"strconv"

	"github.com/rxsxkxd/lim/internal/imaging"
)

// Config は設計書 §8.4 の環境変数に対応する。
// マスク強度に関わる値はサーバー側でのみ決まり、アップローダ側からは弱められない。
type Config struct {
	OutputBucket    string
	InputPrefix     string
	OutputPrefix    string
	PolicyVersion   string
	MaskHeightRatio float64 // 画像上部からマスクする高さの比率（0.5 = 上半分）
	BlurRatio       float64 // 短辺に対するぼかし半径の比率
	MinBlurRadiusPx float64 // 小さい画像向けの半径の絶対下限
	BlurPasses      int     // ボックスぼかしの重ね回数。多いほど滑らかだが遅い
	DownscaleFactor int     // 追加ハードニング。1 で無効
	MaxLaplacianVar float64 // 強度検証の上限。超えたら出力しない
	MaxInputBytes   int64
	MaxInputPixels  int64
	JPEGQuality     int
}

// Load は環境変数から設定を組み立てる。既定値は設計書 §8.4 に合わせている。
func Load() (Config, error) {
	c := Config{
		OutputBucket:    os.Getenv("OUTPUT_BUCKET"),
		InputPrefix:     env("INPUT_PREFIX", "uploads/"),
		OutputPrefix:    env("OUTPUT_PREFIX", "masked/"),
		PolicyVersion:   env("MASKING_POLICY_VERSION", "v1"),
		MaskHeightRatio: envFloat("MASK_HEIGHT_RATIO", 0.5),
		BlurRatio:       envFloat("MIN_BLUR_RATIO", 0.04),
		MinBlurRadiusPx: envFloat("MIN_BLUR_RADIUS_PX", 8),
		BlurPasses:      envInt("BLUR_PASSES", imaging.DefaultBlurPasses),
		DownscaleFactor: envInt("DOWNSCALE_FACTOR", 1),
		MaxLaplacianVar: envFloat("MAX_ALLOWED_LAPLACIAN_VAR", 5.0),
		MaxInputBytes:   int64(envInt("MAX_INPUT_BYTES", 20*1024*1024)),
		MaxInputPixels:  int64(envInt("MAX_INPUT_PIXELS", 64_000_000)),
		JPEGQuality:     envInt("JPEG_QUALITY", 85),
	}

	if c.OutputBucket == "" {
		return c, fmt.Errorf("OUTPUT_BUCKET is required")
	}
	if c.MaskHeightRatio <= 0 || c.MaskHeightRatio > 1 {
		return c, fmt.Errorf("MASK_HEIGHT_RATIO must be in (0, 1], got %v", c.MaskHeightRatio)
	}
	if c.BlurRatio <= 0 {
		return c, fmt.Errorf("MIN_BLUR_RATIO must be > 0, got %v", c.BlurRatio)
	}
	// 1 回だけの移動平均はボックス窓の副ローブが残るため許可しない（imaging.GaussianBlurPasses 参照）。
	if c.BlurPasses < 2 || c.BlurPasses > 5 {
		return c, fmt.Errorf("BLUR_PASSES must be between 2 and 5, got %d", c.BlurPasses)
	}
	if c.DownscaleFactor < 1 {
		return c, fmt.Errorf("DOWNSCALE_FACTOR must be >= 1, got %d", c.DownscaleFactor)
	}
	return c, nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envFloat(k string, def float64) float64 {
	if v := os.Getenv(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}
