// Package imageinput はアップロードされた画像の形式を判別する。これは HTTP 層の技術的な関心事
// (クリーンアーキテクチャ: インバウンドアダプタの一部で、package httpapi が使う)。どの形式を
// 受け付けるかはビジネスルールで、package ticket が決める。重い依存はこのパッケージ内に留める。
package imageinput

import (
	"bytes"
	"errors"
	"image"
	"image/jpeg"
	"image/png"
	"io"

	"github.com/gabriel-vasile/mimetype"
	"go4.org/media/heif"
	"golang.org/x/image/webp"
)

// MaxBytes はランタイムが定めるアップロードの上限: Lambda のリクエストは最大 6MB で、API Gateway は
// バイナリのボディを base64 エンコードする(×4/3)。デプロイごとに MAX_IMAGE_BYTES で下げられる(DESIGN.md 5)。
const MaxBytes = 4 << 20

// validators は、判別された形式のデータが本当にその画像であることを、画像サイズまでヘッダを
// パースして確認する。validator のない形式(HEIF の画像シーケンスを含む)は認識しない。
var validators = map[string]func([]byte) error{
	"image/jpeg": config(jpeg.DecodeConfig),
	"image/png":  config(png.DecodeConfig),
	"image/webp": config(webp.DecodeConfig),
	"image/heic": heifSize,
	"image/heif": heifSize,
	"image/avif": heifSize,
}

// Detect は data の MIME タイプを返す。認識できる画像でなければ "" を返す。mimetype が先頭バイトから
// 形式を判別し、その形式自身のパーサが画像サイズまで読むので、先頭だけ画像に見えるバイト列は
// 拒否される(Node 版の image-size と同様)。
func Detect(data []byte) string {
	mt := mimetype.Detect(data).String()
	if validate, ok := validators[mt]; ok && validate(data) == nil {
		return mt
	}
	return ""
}

// config は image.DecodeConfig 関数を validator に適合させる。
func config(decode func(io.Reader) (image.Config, error)) func([]byte) error {
	return func(data []byte) error {
		_, err := decode(bytes.NewReader(data))
		return err
	}
}

var errNoSize = errors.New("heif: no image size")

// heifSize は HEIF コンテナのプライマリアイテムがサイズ(ispe)を持つことを要求する。読むのはメタデータの
// ボックスだけで、画像そのものはデコードしない。
func heifSize(data []byte) error {
	item, err := heif.Open(bytes.NewReader(data)).PrimaryItem()
	if err != nil {
		return err
	}
	if _, _, ok := item.SpatialExtents(); !ok {
		return errNoSize
	}
	return nil
}
