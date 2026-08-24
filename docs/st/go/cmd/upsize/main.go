// Command upsize は、判定が通る 4MB 以下の画像から、4MB を超える画像を作るテスト用の道具。SPA の縮小
// (web/src/image/shrink.ts)を通して送り、実際の環境の判定が OK になるかを確かめるのに使う(TEST_PROCEDURES.md 3章)。
// デプロイはしない。
//
// 方法(-mode):
//
//	scale  画素数を増やす(既定)。長辺を少しずつ大きくして、-target を超えるまで JPEG(または PNG)に書き直す。
//	       高画素の端末の写真に近い。写真の向き(EXIF の Orientation)は画素に反映してから大きくする
//	pad    画素はそのままで、ファイルにだけ詰め物を足す(JPEG はコメントのセグメント、PNG は補助チャンク)。
//	       元のファイルのバイト列(EXIF を含む)は変えない。画素数が変わらないので、縮めた後の画像は元とほぼ同じ
//
// 使い方:
//
//	go run ./cmd/upsize -in photo.jpg -out big.jpg                 # scale、5MiB を超えるまで
//	go run ./cmd/upsize -in photo.jpg -out big.jpg -target 8MiB -quality 98
//	go run ./cmd/upsize -in photo.jpg -out big.png -format png     # 画素数を増やして PNG にする
//	go run ./cmd/upsize -in photo.jpg -out pad.jpg -mode pad       # 詰め物だけ
//
// 入力は JPEG・PNG・WebP。HEIC は、先に macOS の sips で JPEG にする(sips -s format jpeg in.heic --out in.jpg)。
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	in := flag.String("in", "", "入力の画像(JPEG / PNG / WebP)")
	out := flag.String("out", "", "出力のファイル")
	mode := flag.String("mode", "scale", "scale(画素数を増やす)/ pad(詰め物を足す)")
	target := flag.String("target", "5MiB", "これを超える大きさにする(例: 5MiB、6MB、4194305)")
	format := flag.String("format", "jpeg", "scale の出力形式: jpeg / png")
	quality := flag.Int("quality", 95, "scale で JPEG にするときの画質(1〜100)")
	maxEdge := flag.Int("max-edge", 8192, "scale で大きくする長辺の上限(px)。48MP の写真は 8064×6048")
	flag.Parse()

	if err := run(*in, *out, *mode, *target, *format, *quality, *maxEdge); err != nil {
		fmt.Fprintln(os.Stderr, "upsize:", err)
		os.Exit(1)
	}
}

func run(in, out, mode, targetText, format string, quality, maxEdge int) error {
	if in == "" || out == "" {
		return fmt.Errorf("-in と -out を指定してください")
	}
	target, err := parseSize(targetText)
	if err != nil {
		return err
	}
	src, err := os.ReadFile(in)
	if err != nil {
		return err
	}

	var res result
	switch mode {
	case "scale":
		res, err = scaleUp(src, target, format, quality, maxEdge)
	case "pad":
		res, err = pad(src, target)
	default:
		return fmt.Errorf("-mode は scale か pad: %q", mode)
	}
	if err != nil {
		return err
	}
	if err := os.WriteFile(out, res.data, 0o644); err != nil {
		return err
	}
	fmt.Printf("%s: %s %d×%d, %d bytes (%.1fMB)。元は %d bytes\n",
		out, res.format, res.width, res.height, len(res.data), float64(len(res.data))/(1<<20), len(src))
	return nil
}
