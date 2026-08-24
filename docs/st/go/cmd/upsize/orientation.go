package main

import (
	"bytes"
	"encoding/binary"
	"image"
)

// jpegOrientation は JPEG の EXIF(APP1)の Orientation(1〜8)を返す。なければ 1。スマートフォンの写真は、
// 画素は横向きのまま、この値で表示の向きを指定していることが多い。Go の image/jpeg は EXIF を読まないので、
// 書き直すと向きの指定が消える。そのため、書き直す前に画素に反映する。
func jpegOrientation(src []byte) int {
	if len(src) < 4 || src[0] != 0xFF || src[1] != 0xD8 {
		return 1
	}
	for i := 2; i+4 <= len(src); {
		if src[i] != 0xFF {
			return 1
		}
		marker := src[i+1]
		if marker == 0xDA || marker == 0xD9 { // 画像のデータ(SOS)か終わり(EOI)まで来たら、EXIF はない
			return 1
		}
		size := int(binary.BigEndian.Uint16(src[i+2:]))
		end := i + 2 + size
		if size < 2 || end > len(src) {
			return 1
		}
		if marker == 0xE1 && bytes.HasPrefix(src[i+4:end], []byte("Exif\x00\x00")) {
			return tiffOrientation(src[i+10 : end])
		}
		i = end
	}
	return 1
}

// tiffOrientation は、EXIF の TIFF の部分の最初の IFD から、Orientation(タグ 0x0112)を読む。
func tiffOrientation(t []byte) int {
	if len(t) < 8 {
		return 1
	}
	var bo binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return 1
	}
	ifd := int(bo.Uint32(t[4:]))
	if ifd+2 > len(t) {
		return 1
	}
	n := int(bo.Uint16(t[ifd:]))
	for k := range n {
		e := ifd + 2 + 12*k
		if e+12 > len(t) {
			return 1
		}
		if bo.Uint16(t[e:]) == 0x0112 {
			if v := int(bo.Uint16(t[e+8:])); v >= 1 && v <= 8 {
				return v
			}
			return 1
		}
	}
	return 1
}

// applyOrientation は、Orientation の向きを画素に反映した画像を返す(1 ならそのまま)。
func applyOrientation(img image.Image, o int) image.Image {
	if o <= 1 || o > 8 {
		return img
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	dw, dh := w, h
	if o >= 5 { // 5〜8 は 90 度回す向きなので、縦と横が入れ替わる
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := range h {
		for x := range w {
			var dx, dy int
			switch o {
			case 2: // 左右反転
				dx, dy = w-1-x, y
			case 3: // 180 度
				dx, dy = w-1-x, h-1-y
			case 4: // 上下反転
				dx, dy = x, h-1-y
			case 5: // 左上と右下を結ぶ線で反転
				dx, dy = y, x
			case 6: // 時計回りに 90 度
				dx, dy = h-1-y, x
			case 7: // 右上と左下を結ぶ線で反転
				dx, dy = h-1-y, w-1-x
			case 8: // 反時計回りに 90 度
				dx, dy = y, w-1-x
			}
			dst.Set(dx, dy, img.At(b.Min.X+x, b.Min.Y+y))
		}
	}
	return dst
}
