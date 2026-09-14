// Package config は Lambda の環境変数を読み込む。
package config

import (
	"fmt"
	"os"
	"strconv"

	"github.com/rxsxkxd/lim/internal/imaging"
	"github.com/rxsxkxd/lim/internal/s3key"
)

// MinAllowedBlurRatio はぼかし半径の比率として許容する下限。
//
// 「この強さ以上なら隠れている」と判断したライン（設計書 §12.6）。
// 既定の 0.04 はこの 10 倍にあたる。これを下回る設定は起動時に拒否する。
// マスクの強さはこの値で担保するのであって、出力後の強度検査で担保するのではない。
const MinAllowedBlurRatio = 0.004

// Config は設計書 §8.4 の環境変数に対応する。
// マスク強度に関わる値はサーバー側でのみ決まり、アップローダ側からは弱められない。
type Config struct {
	// キーは <bucket>/<prefix>/<x>/<y>/<infix>/<z>/<n> の形に固定する。
	// 変数（x, y, z, n）は呼び出し側から受け取り、それ以外はここで定義する。
	InputBucket   string // 原本のあるバケット
	OutputBucket  string // マスク済みの出力先。未指定なら InputBucket と同じ
	KeyPrefix     string // 共有バケット内でこのアプリが使うルート
	OriginalInfix string // 原本の階層
	PolicyVersion string // マスク済みの階層（マスキングポリシー版）

	MaskHeightRatio float64 // 画像上部からマスクする高さの比率（0.5 = 上半分）
	BlurRatio       float64 // 短辺に対するぼかし半径の比率
	MinBlurRadiusPx float64 // 小さい画像向けの半径の絶対下限
	BlurPasses      int     // ボックスぼかしの重ね回数。多いほど滑らかだが遅い
	DownscaleFactor int     // マスク領域の縮小率。1 で無効
	StrengthBlockPx int     // 強度検証の区画サイズ
	MaxLaplacianVar float64 // 強度検証の上限。超えたら出力しない
	MaxInputBytes   int64
	MaxInputPixels  int64
	JPEGQuality     int
}

// Load は環境変数から設定を組み立てる。既定値は設計書 §8.4 に合わせている。
func Load() (Config, error) {
	c := Config{
		InputBucket:     os.Getenv("INPUT_BUCKET"),
		OutputBucket:    os.Getenv("OUTPUT_BUCKET"),
		KeyPrefix:       env("KEY_PREFIX", "masking"),
		OriginalInfix:   env("ORIGINAL_INFIX", "original"),
		PolicyVersion:   env("MASKING_POLICY_VERSION", "v1"),
		MaskHeightRatio: envFloat("MASK_HEIGHT_RATIO", 0.5),
		BlurRatio:       envFloat("MIN_BLUR_RATIO", 0.04),
		MinBlurRadiusPx: envFloat("MIN_BLUR_RADIUS_PX", 8),
		BlurPasses:      envInt("BLUR_PASSES", imaging.DefaultBlurPasses),
		DownscaleFactor: envInt("DOWNSCALE_FACTOR", 4),
		StrengthBlockPx: envInt("STRENGTH_BLOCK_PX", imaging.DefaultStrengthBlockPx),
		MaxLaplacianVar: envFloat("MAX_ALLOWED_LAPLACIAN_VAR", 15.0),
		MaxInputBytes:   int64(envInt("MAX_INPUT_BYTES", 20*1024*1024)),
		MaxInputPixels:  int64(envInt("MAX_INPUT_PIXELS", 64_000_000)),
		JPEGQuality:     envInt("JPEG_QUALITY", 85),
	}

	if c.InputBucket == "" {
		return c, fmt.Errorf("INPUT_BUCKET is required")
	}
	if c.OutputBucket == "" {
		// 同一バケットの別 infix に出す構成が既定。
		c.OutputBucket = c.InputBucket
	}
	if err := c.Layout().Validate(); err != nil {
		return c, err
	}
	if c.MaskHeightRatio <= 0 || c.MaskHeightRatio > 1 {
		return c, fmt.Errorf("MASK_HEIGHT_RATIO must be in (0, 1], got %v", c.MaskHeightRatio)
	}
	if c.BlurRatio < MinAllowedBlurRatio {
		// 弱すぎる設定で起動してしまうと、マスクが不十分な画像を出し続ける。
		// 出力してから検査で拾うのではなく、起動時に止める。
		return c, fmt.Errorf("MIN_BLUR_RATIO must be >= %v, got %v", MinAllowedBlurRatio, c.BlurRatio)
	}
	// 1 回だけの移動平均はボックス窓の副ローブが残るため許可しない（imaging.GaussianBlurPasses 参照）。
	if c.BlurPasses < 2 || c.BlurPasses > 5 {
		return c, fmt.Errorf("BLUR_PASSES must be between 2 and 5, got %d", c.BlurPasses)
	}
	if c.StrengthBlockPx < 16 {
		// 区画が小さすぎると標本数が足りず、量子化ノイズを拾った区画が
		// 最悪値に選ばれて誤検知になる。
		return c, fmt.Errorf("STRENGTH_BLOCK_PX must be >= 16, got %d", c.StrengthBlockPx)
	}
	if c.DownscaleFactor < 1 {
		return c, fmt.Errorf("DOWNSCALE_FACTOR must be >= 1, got %d", c.DownscaleFactor)
	}
	return c, nil
}

// Layout はキーの固定部分を返す。
func (c Config) Layout() s3key.Layout {
	return s3key.Layout{
		Prefix:        c.KeyPrefix,
		OriginalInfix: c.OriginalInfix,
		MaskedInfix:   c.PolicyVersion,
	}
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
