package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"image"
	"image/jpeg"
	"image/png"
	"strconv"
	"strings"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp" // 入力に WebP も使えるようにする
)

type result struct {
	data          []byte
	format        string
	width, height int
}

// parseSize は "5MiB"・"6MB"・"4194305" のような大きさをバイト数にする(MB は 10^6、MiB は 2^20)。
func parseSize(s string) (int, error) {
	units := []struct {
		suffix string
		mult   float64
	}{{"MiB", 1 << 20}, {"KiB", 1 << 10}, {"MB", 1e6}, {"KB", 1e3}, {"B", 1}}
	t := strings.TrimSpace(s)
	mult := 1.0
	for _, u := range units {
		if strings.HasSuffix(t, u.suffix) {
			t, mult = strings.TrimSpace(strings.TrimSuffix(t, u.suffix)), u.mult
			break
		}
	}
	v, err := strconv.ParseFloat(t, 64)
	if err != nil || v <= 0 {
		return 0, fmt.Errorf("大きさの指定が読めません: %q", s)
	}
	return int(v * mult), nil
}

// scaleUp は、画像の長辺を少しずつ大きくして、target を超える大きさになるまで書き直す。長辺が maxEdge に
// 達しても超えなければ、エラーにする(画質を上げるか、pad を使う)。
func scaleUp(src []byte, target int, format string, quality, maxEdge int) (result, error) {
	if format != "jpeg" && format != "png" {
		return result{}, fmt.Errorf("-format は jpeg か png: %q", format)
	}
	if quality < 1 || quality > 100 {
		return result{}, fmt.Errorf("-quality は 1〜100: %d", quality)
	}
	img, _, err := image.Decode(bytes.NewReader(src))
	if err != nil {
		return result{}, fmt.Errorf("画像を読めません(JPEG / PNG / WebP。HEIC は sips で JPEG にする): %w", err)
	}
	img = applyOrientation(img, jpegOrientation(src))

	b := img.Bounds()
	long := max(b.Dx(), b.Dy())
	if long > maxEdge {
		return result{}, fmt.Errorf("元の長辺 %dpx が -max-edge %dpx を超えています", long, maxEdge)
	}
	// 元の大きさから始め、長辺を 1.25 倍ずつ、上限まで大きくする。
	for scale := 1.0; ; scale *= 1.25 {
		edge := min(int(float64(long)*scale), maxEdge)
		w, h := b.Dx()*edge/long, b.Dy()*edge/long
		data, err := encode(resize(img, w, h), format, quality)
		if err != nil {
			return result{}, err
		}
		if len(data) > target {
			return result{data: data, format: format, width: w, height: h}, nil
		}
		if edge == maxEdge {
			return result{}, fmt.Errorf("長辺を %dpx にしても %d bytes で、%d bytes を超えません。-quality を上げるか、-max-edge を上げるか、-mode pad を使ってください", edge, len(data), target)
		}
	}
}

func resize(img image.Image, w, h int) image.Image {
	if b := img.Bounds(); b.Dx() == w && b.Dy() == h {
		return img
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, img.Bounds(), draw.Src, nil)
	return dst
}

func encode(img image.Image, format string, quality int) ([]byte, error) {
	var buf bytes.Buffer
	var err error
	if format == "png" {
		err = png.Encode(&buf, img)
	} else {
		err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: quality})
	}
	return buf.Bytes(), err
}

var pngSignature = []byte("\x89PNG\r\n\x1a\n")

// pad は、画素とほかのバイト列を変えずに、詰め物を足して target を超える大きさにする。
//   - JPEG: SOI の直後に、コメントのセグメント(COM、0xFFFE)を必要な数だけ入れる。デコーダーは読み飛ばす
//   - PNG: IEND の前に、補助チャンク(名前 "upSz"。小文字で始まるのでデコーダーは読み飛ばす)を入れる
func pad(src []byte, target int) (result, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(src))
	if err != nil {
		return result{}, fmt.Errorf("画像を読めません: %w", err)
	}
	need := target + 1 - len(src)
	if need <= 0 {
		return result{}, fmt.Errorf("元の大きさ %d bytes が、すでに %d bytes を超えています", len(src), target)
	}
	var out []byte
	switch format {
	case "jpeg":
		out = padJPEG(src, need)
	case "png":
		out, err = padPNG(src, need)
		if err != nil {
			return result{}, err
		}
	default:
		return result{}, fmt.Errorf("pad で使えるのは JPEG と PNG だけ: %s", format)
	}
	return result{data: out, format: format, width: cfg.Width, height: cfg.Height}, nil
}

func padJPEG(src []byte, need int) []byte {
	const maxPayload = 65533 // セグメントの長さ(2 バイト)は、長さ自身を含めて 65535 まで
	var segs bytes.Buffer
	for remaining := need; remaining > 0; {
		n := min(remaining, maxPayload+4) - 4 // マーカー 2 バイトと長さ 2 バイトを含めた大きさで数える
		n = max(n, 0)
		segs.Write([]byte{0xFF, 0xFE})
		_ = binary.Write(&segs, binary.BigEndian, uint16(n+2))
		segs.Write(bytes.Repeat([]byte{' '}, n))
		remaining -= n + 4
	}
	out := make([]byte, 0, len(src)+segs.Len())
	out = append(out, src[:2]...) // SOI
	out = append(out, segs.Bytes()...)
	return append(out, src[2:]...)
}

func padPNG(src []byte, need int) ([]byte, error) {
	if !bytes.HasPrefix(src, pngSignature) {
		return nil, errors.New("PNG の先頭が正しくありません")
	}
	iend := bytes.LastIndex(src, []byte("IEND"))
	if iend < 4 {
		return nil, errors.New("PNG に IEND がありません")
	}
	iend -= 4            // IEND のチャンクの長さの欄から
	n := max(need-12, 0) // 長さ・名前・CRC の 12 バイトを除いた中身
	chunk := make([]byte, 0, n+12)
	chunk = binary.BigEndian.AppendUint32(chunk, uint32(n))
	body := append([]byte("upSz"), make([]byte, n)...)
	chunk = append(chunk, body...)
	chunk = binary.BigEndian.AppendUint32(chunk, crc32.ChecksumIEEE(body))
	out := make([]byte, 0, len(src)+len(chunk))
	out = append(out, src[:iend]...)
	out = append(out, chunk...)
	return append(out, src[iend:]...), nil
}
