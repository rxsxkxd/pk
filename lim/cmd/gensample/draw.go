package main

import (
	"image"
	"image/color"
	"math"
	"math/rand"

	"github.com/rxsxkxd/lim/internal/imaging"
)

// canvas は 3 倍のスーパーサンプリングで描画し、最後に縮小してアンチエイリアスを得る。
// 図形の輪郭がギザギザだと実写と傾向が変わり、ぼかしの効き方の確認に使いにくい。
type canvas struct {
	img *image.RGBA
	ss  int
}

func newCanvas(w, h int) *canvas {
	const ss = 3
	return &canvas{img: image.NewRGBA(image.Rect(0, 0, w*ss, h*ss)), ss: ss}
}

// resolve は縮小して等倍の画像を返す。
func (c *canvas) resolve() *image.RGBA { return imaging.Downscale(c.img, c.ss) }

func (c *canvas) rect(x0, y0, x1, y1 float64, col color.RGBA) {
	s := float64(c.ss)
	for y := int(y0 * s); y < int(y1*s); y++ {
		for x := int(x0 * s); x < int(x1*s); x++ {
			c.set(x, y, col)
		}
	}
}

// roundRect は角丸の矩形。カードや衣服の輪郭に使う。
func (c *canvas) roundRect(x0, y0, x1, y1, r float64, col color.RGBA) {
	c.rect(x0+r, y0, x1-r, y1, col)
	c.rect(x0, y0+r, x1, y1-r, col)
	c.ellipse(x0+r, y0+r, r, r, col)
	c.ellipse(x1-r, y0+r, r, r, col)
	c.ellipse(x0+r, y1-r, r, r, col)
	c.ellipse(x1-r, y1-r, r, r, col)
}

func (c *canvas) ellipse(cx, cy, rx, ry float64, col color.RGBA) {
	s := float64(c.ss)
	for y := int((cy - ry) * s); y <= int((cy+ry)*s); y++ {
		for x := int((cx - rx) * s); x <= int((cx+rx)*s); x++ {
			dx := (float64(x)/s - cx) / rx
			dy := (float64(y)/s - cy) / ry
			if dx*dx+dy*dy <= 1 {
				c.set(x, y, col)
			}
		}
	}
}

// ellipseFrom は y >= yMin の部分だけを塗る楕円。
// 髪を描いたあとに顔を生え際から下だけ描き直すのに使う。
func (c *canvas) ellipseFrom(cx, cy, rx, ry, yMin float64, col color.RGBA) {
	s := float64(c.ss)
	for y := int((cy - ry) * s); y <= int((cy+ry)*s); y++ {
		if float64(y)/s < yMin {
			continue
		}
		for x := int((cx - rx) * s); x <= int((cx+rx)*s); x++ {
			dx := (float64(x)/s - cx) / rx
			dy := (float64(y)/s - cy) / ry
			if dx*dx+dy*dy <= 1 {
				c.set(x, y, col)
			}
		}
	}
}

// ellipseArc は角度で切り取った楕円。口や髪の生え際に使う。
func (c *canvas) ellipseArc(cx, cy, rx, ry, from, to float64, col color.RGBA) {
	s := float64(c.ss)
	for y := int((cy - ry) * s); y <= int((cy+ry)*s); y++ {
		for x := int((cx - rx) * s); x <= int((cx+rx)*s); x++ {
			px, py := float64(x)/s-cx, float64(y)/s-cy
			dx, dy := px/rx, py/ry
			if dx*dx+dy*dy > 1 {
				continue
			}
			ang := math.Atan2(py, px)
			if ang >= from && ang <= to {
				c.set(x, y, col)
			}
		}
	}
}

// verticalGradient は上下のグラデーション。背景に使う。
func (c *canvas) verticalGradient(top, bottom color.RGBA) {
	b := c.img.Bounds()
	for y := 0; y < b.Dy(); y++ {
		t := float64(y) / float64(b.Dy())
		col := lerp(top, bottom, t)
		for x := 0; x < b.Dx(); x++ {
			c.set(x, y, col)
		}
	}
}

// vignette は周辺を落とす。実写らしさが出るのと、一様な背景より
// ぼかし後のスコアが現実に近くなる。
func (c *canvas) vignette(strength float64) {
	b := c.img.Bounds()
	cx, cy := float64(b.Dx())/2, float64(b.Dy())/2
	maxD := math.Hypot(cx, cy)
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			d := math.Hypot(float64(x)-cx, float64(y)-cy) / maxD
			f := 1 - strength*d*d
			o := c.img.PixOffset(x, y)
			for i := 0; i < 3; i++ {
				c.img.Pix[o+i] = uint8(float64(c.img.Pix[o+i]) * f)
			}
		}
	}
}

// stroke は太さのある線分。署名など、つながった筆跡を描くのに使う。
func (c *canvas) stroke(x0, y0, x1, y1, width float64, col color.RGBA) {
	steps := int(math.Hypot(x1-x0, y1-y0)*float64(c.ss)) + 1
	for i := 0; i <= steps; i++ {
		t := float64(i) / float64(steps)
		c.ellipse(x0+(x1-x0)*t, y0+(y1-y0)*t, width/2, width/2, col)
	}
}

func (c *canvas) set(x, y int, col color.RGBA) {
	if !(image.Point{x, y}).In(c.img.Bounds()) {
		return
	}
	c.img.SetRGBA(x, y, col)
}

// addNoise は撮影ノイズを加える。実写は必ず微細なノイズを持っており、
// これがないとラプラシアン分散が現実より低く出てしきい値調整の役に立たない。
func addNoise(img *image.RGBA, rnd *rand.Rand, amount float64) {
	b := img.Bounds()
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			n := (rnd.Float64()*2 - 1) * amount
			o := img.PixOffset(x, y)
			for i := 0; i < 3; i++ {
				img.Pix[o+i] = clamp8(float64(img.Pix[o+i]) + n)
			}
		}
	}
}

func lerp(a, b color.RGBA, t float64) color.RGBA {
	return color.RGBA{
		clamp8(float64(a.R) + (float64(b.R)-float64(a.R))*t),
		clamp8(float64(a.G) + (float64(b.G)-float64(a.G))*t),
		clamp8(float64(a.B) + (float64(b.B)-float64(a.B))*t),
		255,
	}
}

func clamp8(v float64) uint8 {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return uint8(v + 0.5)
}
