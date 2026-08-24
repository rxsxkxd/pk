package imaging

import (
	"encoding/binary"
	"image"
)

// Orientation は EXIF の Orientation タグ値（1..8）。0 は不明・未指定。
type Orientation int

// JPEGOrientation は JPEG バイト列の APP1 (EXIF) セグメントから Orientation を読む。
//
// 出力ではメタデータを一切引き継がない（設計書 FR-9）ため、向き情報は
// ここで読み取って画素そのものに反映させる必要がある。
// 外部依存を増やさないよう、必要なタグ 1 つだけを読む最小実装にしている。
func JPEGOrientation(b []byte) Orientation {
	if len(b) < 4 || b[0] != 0xFF || b[1] != 0xD8 {
		return 0
	}
	i := 2
	for i+4 <= len(b) {
		if b[i] != 0xFF {
			return 0
		}
		marker := b[i+1]
		// スタンドアロンマーカー（長さフィールドを持たない）
		if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
			i += 2
			continue
		}
		// 画像データ開始。ここから先に EXIF はない。
		if marker == 0xDA || marker == 0xD9 {
			return 0
		}
		if i+4 > len(b) {
			return 0
		}
		segLen := int(binary.BigEndian.Uint16(b[i+2 : i+4]))
		if segLen < 2 || i+2+segLen > len(b) {
			return 0
		}
		if marker == 0xE1 {
			payload := b[i+4 : i+2+segLen]
			if o := orientationFromTIFF(payload); o != 0 {
				return o
			}
		}
		i += 2 + segLen
	}
	return 0
}

func orientationFromTIFF(p []byte) Orientation {
	const header = "Exif\x00\x00"
	if len(p) < len(header)+8 || string(p[:len(header)]) != header {
		return 0
	}
	tiff := p[len(header):]

	var bo binary.ByteOrder
	switch {
	case tiff[0] == 'I' && tiff[1] == 'I':
		bo = binary.LittleEndian
	case tiff[0] == 'M' && tiff[1] == 'M':
		bo = binary.BigEndian
	default:
		return 0
	}
	if bo.Uint16(tiff[2:4]) != 42 {
		return 0
	}

	ifdOff := int(bo.Uint32(tiff[4:8]))
	if ifdOff+2 > len(tiff) {
		return 0
	}
	count := int(bo.Uint16(tiff[ifdOff : ifdOff+2]))
	for e := 0; e < count; e++ {
		off := ifdOff + 2 + e*12
		if off+12 > len(tiff) {
			return 0
		}
		if bo.Uint16(tiff[off:off+2]) != 0x0112 { // Orientation
			continue
		}
		v := Orientation(bo.Uint16(tiff[off+8 : off+10]))
		if v >= 1 && v <= 8 {
			return v
		}
		return 0
	}
	return 0
}

// ApplyOrientation は EXIF Orientation を画素に反映し、見た目の向きを正す。
func ApplyOrientation(src *image.RGBA, o Orientation) *image.RGBA {
	if o <= 1 || o > 8 {
		return src
	}
	w, h := src.Rect.Dx(), src.Rect.Dy()

	// 5..8 は 90 度回転を伴うため縦横が入れ替わる。
	dw, dh := w, h
	if o >= 5 {
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))

	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var nx, ny int
			switch o {
			case 2: // 左右反転
				nx, ny = w-1-x, y
			case 3: // 180 度回転
				nx, ny = w-1-x, h-1-y
			case 4: // 上下反転
				nx, ny = x, h-1-y
			case 5: // 転置
				nx, ny = y, x
			case 6: // 時計回り 90 度
				nx, ny = h-1-y, x
			case 7: // 反転転置
				nx, ny = h-1-y, w-1-x
			case 8: // 反時計回り 90 度
				nx, ny = y, w-1-x
			}
			copy(dst.Pix[ny*dst.Stride+nx*4:][:4], src.Pix[y*src.Stride+x*4:][:4])
		}
	}
	return dst
}
