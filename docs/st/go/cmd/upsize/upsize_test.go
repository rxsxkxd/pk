package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

// sample は、圧縮で小さくなりすぎないよう、模様のある画像を作る。
func sample(w, h int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		for x := range w {
			img.Set(x, y, color.RGBA{uint8(x * 7), uint8(y * 13), uint8((x ^ y) * 3), 255})
		}
	}
	return img
}

func jpegBytes(t *testing.T, img image.Image) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// withOrientation は、JPEG の SOI の直後に、Orientation だけを持つ EXIF(APP1)を入れる。
func withOrientation(src []byte, o uint16) []byte {
	var tiff bytes.Buffer
	tiff.WriteString("MM\x00\x2a")
	_ = binary.Write(&tiff, binary.BigEndian, uint32(8))           // 最初の IFD の位置
	_ = binary.Write(&tiff, binary.BigEndian, uint16(1))           // 項目の数
	_ = binary.Write(&tiff, binary.BigEndian, []uint16{0x0112, 3}) // Orientation、SHORT
	_ = binary.Write(&tiff, binary.BigEndian, uint32(1))
	_ = binary.Write(&tiff, binary.BigEndian, []uint16{o, 0})
	_ = binary.Write(&tiff, binary.BigEndian, uint32(0)) // 次の IFD はない
	payload := append([]byte("Exif\x00\x00"), tiff.Bytes()...)
	app1 := []byte{0xFF, 0xE1}
	app1 = binary.BigEndian.AppendUint16(app1, uint16(len(payload)+2))
	app1 = append(app1, payload...)
	out := append([]byte{}, src[:2]...)
	out = append(out, app1...)
	return append(out, src[2:]...)
}

func TestParseSize(t *testing.T) {
	for in, want := range map[string]int{"5MiB": 5 << 20, "6MB": 6_000_000, "4194305": 4194305, "512KiB": 512 << 10, "1.5 MiB": 3 << 19} {
		if got, err := parseSize(in); err != nil || got != want {
			t.Errorf("parseSize(%q) = %d, %v; want %d", in, got, err, want)
		}
	}
	for _, in := range []string{"", "abc", "-1MB", "0"} {
		if _, err := parseSize(in); err == nil {
			t.Errorf("parseSize(%q): want an error", in)
		}
	}
}

func TestPadJPEGKeepsThePixels(t *testing.T) {
	src := withOrientation(jpegBytes(t, sample(64, 48)), 6)
	res, err := pad(src, 300_000)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.data) <= 300_000 || res.format != "jpeg" || res.width != 64 || res.height != 48 {
		t.Fatalf("len = %d, %s %d×%d", len(res.data), res.format, res.width, res.height)
	}
	before, _ := jpeg.Decode(bytes.NewReader(src))
	after, err := jpeg.Decode(bytes.NewReader(res.data))
	if err != nil {
		t.Fatal(err)
	}
	if !sameImage(before, after) {
		t.Error("the pixels changed")
	}
	if jpegOrientation(res.data) != 6 {
		t.Error("the EXIF orientation was lost")
	}
}

func TestPadPNGKeepsThePixels(t *testing.T) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, sample(64, 48)); err != nil {
		t.Fatal(err)
	}
	res, err := pad(buf.Bytes(), 200_000)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.data) <= 200_000 || res.format != "png" {
		t.Fatalf("len = %d, %s", len(res.data), res.format)
	}
	after, err := png.Decode(bytes.NewReader(res.data)) // CRC が合わないと読めない
	if err != nil {
		t.Fatal(err)
	}
	if !sameImage(sample(64, 48), after) {
		t.Error("the pixels changed")
	}
}

func TestPadRefusesAFileAlreadyOverTheTarget(t *testing.T) {
	if _, err := pad(jpegBytes(t, sample(64, 48)), 10); err == nil {
		t.Error("want an error")
	}
}

func TestScaleUpGrowsUntilOverTheTarget(t *testing.T) {
	src := jpegBytes(t, sample(200, 150))
	for _, format := range []string{"jpeg", "png"} {
		res, err := scaleUp(src, 200_000, format, 95, 4000)
		if err != nil {
			t.Fatal(err)
		}
		if len(res.data) <= 200_000 || res.width <= 200 || res.width*150 != res.height*200 {
			t.Fatalf("%s: len = %d, %d×%d", format, len(res.data), res.width, res.height)
		}
		img, kind, err := image.Decode(bytes.NewReader(res.data))
		if err != nil || kind != format || img.Bounds().Dx() != res.width {
			t.Fatalf("%s: decode = %v, %s", format, err, kind)
		}
	}
}

func TestScaleUpGivesUpAtMaxEdge(t *testing.T) {
	if _, err := scaleUp(jpegBytes(t, sample(200, 150)), 50_000_000, "jpeg", 95, 400); err == nil {
		t.Error("want an error")
	}
}

func TestScaleUpAppliesTheOrientation(t *testing.T) {
	// 横長の画素に「時計回りに 90 度」の指定: 書き直した画像は縦長になる
	src := withOrientation(jpegBytes(t, sample(200, 150)), 6)
	res, err := scaleUp(src, 100_000, "jpeg", 95, 4000)
	if err != nil {
		t.Fatal(err)
	}
	if res.width >= res.height {
		t.Fatalf("%d×%d, want portrait", res.width, res.height)
	}
}

func TestApplyOrientation(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 3, 2))
	mark := color.RGBA{255, 0, 0, 255}
	img.Set(0, 0, mark) // 左上
	for o, want := range map[int]image.Point{
		1: {0, 0}, 2: {2, 0}, 3: {2, 1}, 4: {0, 1},
		5: {0, 0}, 6: {1, 0}, 7: {1, 2}, 8: {0, 2},
	} {
		got := applyOrientation(img, o)
		if got.At(want.X, want.Y) != color.Color(mark) {
			t.Errorf("orientation %d: the top-left pixel is not at %v", o, want)
		}
	}
}

func sameImage(a, b image.Image) bool {
	if a.Bounds() != b.Bounds() {
		return false
	}
	for y := a.Bounds().Min.Y; y < a.Bounds().Max.Y; y++ {
		for x := a.Bounds().Min.X; x < a.Bounds().Max.X; x++ {
			r1, g1, b1, a1 := a.At(x, y).RGBA()
			r2, g2, b2, a2 := b.At(x, y).RGBA()
			if r1 != r2 || g1 != g2 || b1 != b2 || a1 != a2 {
				return false
			}
		}
	}
	return true
}
