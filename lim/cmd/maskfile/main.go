// Command maskfile はマスキング処理をローカルのファイルに対して実行する。
//
// Lambda ハンドラと同じ internal/masking を呼ぶため、ここで確認した結果は
// 本番の挙動と一致する。目視確認と、MAX_ALLOWED_LAPLACIAN_VAR の
// キャリブレーション（設計書 §12.4）に使う。
//
//	maskfile -out masked.jpg photo.jpg
//	maskfile -out-dir ./out ./samples/*.jpg
//	maskfile -report-only -json ./samples/*.jpg    # しきい値の分布を取る
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/rxsxkxd/lim/internal/imaging"
	"github.com/rxsxkxd/lim/internal/masking"
)

func main() {
	var (
		out        = flag.String("out", "", "出力ファイル（例: tmp/masked.jpg）。入力が 1 つのときのみ有効。途中のディレクトリは自動で作る")
		outDir     = flag.String("out-dir", "", "出力ディレクトリ。入力が複数のとき使う。なければ作る")
		reportOnly = flag.Bool("report-only", false, "出力を書かず、スコアだけ表示する（しきい値調整用）")
		asJSON     = flag.Bool("json", false, "1 行 1 件の JSON で出力する")

		heightRatio = flag.Float64("mask-height-ratio", 0.5, "上部からマスクする高さの比率。1.0 で全面")
		blurRatio   = flag.Float64("blur-ratio", 0.04, "短辺に対するぼかし半径の比率")
		minRadius   = flag.Float64("min-blur-radius-px", 8, "ぼかし半径の絶対下限")
		passes      = flag.Int("blur-passes", imaging.DefaultBlurPasses, "ボックスぼかしの重ね回数。多いほど滑らかだが遅い")
		downscale   = flag.Int("downscale-factor", 4, "マスク領域の縮小率。1 で無効")
		block       = flag.Int("strength-block", imaging.DefaultStrengthBlockPx, "強度検証の区画サイズ（px）")
		maxVar      = flag.Float64("max-laplacian-var", 15.0, "強度検証のしきい値（区画ごとの最悪値に対して）")
		maxPixels   = flag.Int64("max-pixels", 64_000_000, "総ピクセル数の上限")
		quality     = flag.Int("jpeg-quality", 85, "JPEG 出力品質")
	)
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: maskfile [flags] <input image>...\n\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	inputs := flag.Args()
	if len(inputs) == 0 {
		flag.Usage()
		os.Exit(2)
	}
	if len(inputs) > 1 && *out != "" {
		fmt.Fprintln(os.Stderr, "error: -out は入力 1 つのときだけ使えます。複数なら -out-dir を使ってください")
		os.Exit(2)
	}
	if !*reportOnly && *out == "" && *outDir == "" {
		fmt.Fprintln(os.Stderr, "error: -out / -out-dir / -report-only のいずれかを指定してください")
		os.Exit(2)
	}
	if *outDir != "" {
		if err := os.MkdirAll(*outDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
	}

	opts := masking.Options{
		MaskHeightRatio: *heightRatio,
		BlurRatio:       *blurRatio,
		MinBlurRadiusPx: *minRadius,
		BlurPasses:      *passes,
		DownscaleFactor: *downscale,
		StrengthBlockPx: *block,
		MaxLaplacianVar: *maxVar,
		MaxPixels:       *maxPixels,
		JPEGQuality:     *quality,
	}

	var failed int
	for _, in := range inputs {
		if err := process(in, *out, *outDir, *reportOnly, *asJSON, opts); err != nil {
			failed++
			report(*asJSON, record{Input: in, Error: err.Error(), Kind: classify(err)})
		}
	}
	if failed > 0 {
		fmt.Fprintf(os.Stderr, "\n%d/%d 件が失敗しました\n", failed, len(inputs))
		os.Exit(1)
	}
}

type record struct {
	Input       string  `json:"input"`
	Output      string  `json:"output,omitempty"`
	Format      string  `json:"format,omitempty"`
	Width       int     `json:"width,omitempty"`
	Height      int     `json:"height,omitempty"`
	RadiusPx    float64 `json:"radiusPx,omitempty"`
	Region      string  `json:"region,omitempty"`
	Score       float64 `json:"strengthScore"`
	Limit       float64 `json:"strengthLimit,omitempty"`
	InputBytes  int     `json:"inputBytes,omitempty"`
	OutputBytes int     `json:"outputBytes,omitempty"`
	DurationMs  int64   `json:"durationMs,omitempty"`
	Error       string  `json:"error,omitempty"`
	Kind        string  `json:"kind,omitempty"`
}

func process(in, out, outDir string, reportOnly, asJSON bool, opts masking.Options) error {
	raw, err := os.ReadFile(in)
	if err != nil {
		return err
	}

	started := time.Now()
	res, err := masking.Apply(raw, opts)
	elapsed := time.Since(started)
	if err != nil {
		return err
	}

	rec := record{
		Input:       in,
		Format:      res.Format,
		Width:       res.Width,
		Height:      res.Height,
		RadiusPx:    res.RadiusPx,
		Region:      res.Region,
		Score:       res.Score,
		Limit:       opts.MaxLaplacianVar,
		InputBytes:  len(raw),
		OutputBytes: len(res.Body),
		DurationMs:  elapsed.Milliseconds(),
	}

	if !reportOnly {
		dst := out
		if dst == "" {
			dst = filepath.Join(outDir, filepath.Base(in))
		}
		if abs, err := filepath.Abs(dst); err == nil {
			if inAbs, err := filepath.Abs(in); err == nil && abs == inAbs {
				return fmt.Errorf("出力先が入力と同じです: %s", dst)
			}
		}
		// tmp/masked.jpg のように掘った先を指定できるよう、途中のディレクトリを作る。
		if dir := filepath.Dir(dst); dir != "." {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return err
			}
		}
		if err := os.WriteFile(dst, res.Body, 0o644); err != nil {
			return err
		}
		rec.Output = dst
	}

	report(asJSON, rec)
	return nil
}

func report(asJSON bool, rec record) {
	if asJSON {
		b, _ := json.Marshal(rec)
		fmt.Println(string(b))
		return
	}
	if rec.Error != "" {
		fmt.Printf("%-28s FAILED (%s) %s\n", rec.Input, rec.Kind, rec.Error)
		return
	}
	verdict := "ok"
	if rec.Score > rec.Limit {
		verdict = "WEAK"
	}
	fmt.Printf("%-28s %s %dx%d  radius=%.0fpx  %s  score=%.4f (limit %.1f, %s)  %s  %dms\n",
		rec.Input, rec.Format, rec.Width, rec.Height, rec.RadiusPx, rec.Region,
		rec.Score, rec.Limit, verdict, sizeDelta(rec), rec.DurationMs)
	if rec.Output != "" {
		fmt.Printf("%-28s -> %s\n", "", rec.Output)
	}
}

func sizeDelta(rec record) string {
	return fmt.Sprintf("%s->%s", human(rec.InputBytes), human(rec.OutputBytes))
}

func human(n int) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1fMB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.0fKB", float64(n)/(1<<10))
	default:
		return fmt.Sprintf("%dB", n)
	}
}

// classify はエラーの分類を返す。本番では validation / strength が DLQ 行きになる。
func classify(err error) string {
	var se *masking.StrengthError
	if errors.As(err, &se) {
		return "strength"
	}
	var ve *masking.ValidationError
	if errors.As(err, &ve) {
		return "validation"
	}
	if strings.Contains(err.Error(), "no such file") {
		return "io"
	}
	return "other"
}
