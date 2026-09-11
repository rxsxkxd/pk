// Command gensample は動作確認・性能計測用のサンプル画像を生成する。
//
// 手元に試せる画像がないとき、また §13.2 の性能計測を再現するときに使う。
// 実写真は使わない（機密画像をリポジトリに置かないため）。
//
//	go run ./cmd/gensample              # testdata/ へ生成
//	go run ./cmd/gensample -out-dir /tmp/x
package main

import (
	"flag"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
)

func main() {
	outDir := flag.String("out-dir", "testdata", "生成先ディレクトリ")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	type job struct {
		name string
		gen  func() *image.RGBA
	}
	jobs := []job{
		// 全身の人物を引きで捉えた構図。頭部が上半分に入るので、マスク後に
		// 「顔が判別できない」「脚や床は鮮明なまま」を一目で確認できる。
		{"person.jpg", func() *image.RGBA { return figure(1200, 900) }},
		{"person.png", func() *image.RGBA { return figure(1200, 900) }},
		// 身分証のレイアウト。顔写真と氏名・番号が上半分、署名とバーコードが下半分。
		// 実際のマスキング用途に最も近い。
		{"idcard.jpg", func() *image.RGBA { return idCard(1200, 900) }},
		// 性能計測用（設計書 §13.2 の 4000x3000 はこれ）。
		{"big.jpg", func() *image.RGBA { return figure(4000, 3000) }},
		// ぼかし半径が下限 8px に張り付くケース。
		{"small.png", func() *image.RGBA { return figure(120, 90) }},
	}

	for _, j := range jobs {
		img := j.gen()
		path := filepath.Join(*outDir, j.name)
		if err := write(path, img); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		st, _ := os.Stat(path)
		fmt.Printf("%-22s %dx%d %d bytes\n", path, img.Rect.Dx(), img.Rect.Dy(), st.Size())
	}

	// 画像でないファイル。検証エラー（DLQ 行き）の確認用。
	broken := filepath.Join(*outDir, "broken.jpg")
	if err := os.WriteFile(broken, []byte("%PDF-1.7 this is definitely not an image"), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("%-22s (not an image; expect a validation error)\n", broken)
}

func write(path string, img *image.RGBA) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	if filepath.Ext(path) == ".png" {
		return png.Encode(f, img)
	}
	return jpeg.Encode(f, img, &jpeg.Options{Quality: 90})
}
