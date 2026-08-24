package main

import (
	"image"
	"image/color"
	"math"
	"math/rand"
)

// 配色。実写の階調に近い値を選んでいる。
var (
	backdropTop = color.RGBA{104, 118, 138, 255}
	backdropBot = color.RGBA{54, 64, 80, 255}
	clothing    = color.RGBA{48, 68, 104, 255}
	clothShadow = color.RGBA{36, 52, 80, 255}
	skin        = color.RGBA{232, 194, 168, 255}
	skinShadow  = color.RGBA{206, 166, 140, 255}
	hair        = color.RGBA{58, 44, 38, 255}
	sclera      = color.RGBA{244, 242, 238, 255}
	iris        = color.RGBA{74, 58, 46, 255}
	pupil       = color.RGBA{22, 20, 20, 255}
	lips        = color.RGBA{178, 106, 100, 255}
	cardPaper   = color.RGBA{246, 245, 241, 255}
	cardHeader  = color.RGBA{38, 70, 118, 255}
	inkDark     = color.RGBA{58, 58, 66, 255}
	inkLight    = color.RGBA{132, 134, 142, 255}
	deskTop     = color.RGBA{126, 106, 88, 255}
	deskBot     = color.RGBA{92, 76, 62, 255}
)

// bust は人物のバストアップ。身分証の顔写真に使う。
func bust(w, h int) *image.RGBA {
	rnd := rand.New(rand.NewSource(1))
	c := newCanvas(w, h)
	fw, fh := float64(w), float64(h)

	c.verticalGradient(backdropTop, backdropBot)

	// 首
	c.rect(fw*0.445, fh*0.32, fw*0.555, fh*0.60, skinShadow)

	// 肩と胴体。下半分に置き、マスクされない領域の「鮮明さ」の基準にする。
	c.ellipse(fw*0.5, fh*1.05, fw*0.52, fh*0.42, clothing)
	// 襟と前立て。下半分にエッジを作り、ぼけていないことを見分けやすくする。
	c.ellipseArc(fw*0.5, fh*0.585, fw*0.155, fh*0.105, 0.25, 2.90, clothShadow)
	c.ellipseArc(fw*0.5, fh*0.585, fw*0.062, fh*0.075, 0.45, 2.70, skinShadow)
	c.rect(fw*0.493, fh*0.66, fw*0.507, fh*1.0, clothShadow)
	for i := 0; i < 3; i++ {
		c.ellipse(fw*0.5, fh*(0.72+float64(i)*0.12), fw*0.010, fh*0.013, backdropBot)
	}

	// 頭。髪を先に置き、顔を生え際から下だけ描き直す。
	headCX, headCY := fw*0.5, fh*0.245
	headRX, headRY := fw*0.135, fh*0.185
	c.ellipse(headCX, headCY-headRY*0.16, headRX*1.10, headRY*1.02, hair)

	// 耳
	c.ellipse(headCX-headRX*0.97, headCY+headRY*0.12, headRX*0.15, headRY*0.17, skinShadow)
	c.ellipse(headCX+headRX*0.97, headCY+headRY*0.12, headRX*0.15, headRY*0.17, skinShadow)

	// 顔（生え際 = 額の上端から下）
	c.ellipseFrom(headCX, headCY, headRX, headRY, headCY-headRY*0.48, skin)

	eyeY := headCY - headRY*0.08
	eyeDX := headRX * 0.42
	eyeRX, eyeRY := headRX*0.22, headRY*0.11

	for _, sx := range []float64{-1, 1} {
		ex := headCX + sx*eyeDX
		// 眉
		c.ellipse(ex, eyeY-headRY*0.30, eyeRX*1.15, eyeRY*0.42, hair)
		// 白目 → 虹彩 → 瞳孔
		c.ellipse(ex, eyeY, eyeRX, eyeRY, sclera)
		c.ellipse(ex, eyeY, eyeRY*0.82, eyeRY*0.82, iris)
		c.ellipse(ex, eyeY, eyeRY*0.38, eyeRY*0.38, pupil)
		// ハイライト
		c.ellipse(ex-eyeRY*0.28, eyeY-eyeRY*0.30, eyeRY*0.18, eyeRY*0.18, sclera)
	}

	// 鼻（陰影のみ）と口
	c.ellipse(headCX, headCY+headRY*0.26, headRX*0.10, headRY*0.13, skinShadow)
	c.ellipseArc(headCX, headCY+headRY*0.52, headRX*0.28, headRY*0.14, 0, 3.15, lips)

	img := c.resolve()
	addNoise(img, rnd, 4)
	return img
}

// idCard は身分証らしいレイアウト。顔写真と氏名・番号が上半分に、
// 署名欄とバーコードが下半分に来る。マスキングの想定に最も近い。
func idCard(w, h int) *image.RGBA {
	rnd := rand.New(rand.NewSource(2))
	c := newCanvas(w, h)
	fw, fh := float64(w), float64(h)

	// 机の上に置かれたカード
	c.verticalGradient(deskTop, deskBot)
	c.roundRect(fw*0.06, fh*0.08, fw*0.94, fh*0.92, fw*0.02, cardPaper)
	c.rect(fw*0.06, fh*0.08, fw*0.94, fh*0.22, cardHeader)

	// ヘッダーの文字列（帯で表現）
	textBar(c, fw*0.10, fh*0.13, fw*0.34, fh*0.04, color.RGBA{236, 240, 246, 255})

	// 顔写真。カード内に人物を縮小して貼り込む。
	px0, py0 := fw*0.10, fh*0.27
	pw, ph := fw*0.24, fh*0.40
	face := bust(int(pw), int(ph))
	for y := 0; y < face.Rect.Dy(); y++ {
		for x := 0; x < face.Rect.Dx(); x++ {
			col := face.RGBAAt(x, y)
			for sy := 0; sy < c.ss; sy++ {
				for sx := 0; sx < c.ss; sx++ {
					c.set(int(px0)*c.ss+x*c.ss+sx, int(py0)*c.ss+y*c.ss+sy, col)
				}
			}
		}
	}
	// 写真の枠
	frame(c, px0, py0, px0+pw, py0+ph, fw*0.004, inkDark)

	// 氏名・生年月日・番号。長さの違う帯で文字列らしく見せる。
	labelX := fw * 0.40
	rows := []struct{ label, value float64 }{
		{0.10, 0.34},
		{0.12, 0.28},
		{0.09, 0.42},
		{0.14, 0.22},
	}
	y := fh * 0.29
	for _, r := range rows {
		textBar(c, labelX, y, fw*r.label, fh*0.022, inkLight)
		textBar(c, labelX, y+fh*0.045, fw*r.value, fh*0.035, inkDark)
		y += fh * 0.115
	}

	// 署名欄。つながった筆跡に見えるよう、波形を線分でつないで描く。
	sigY := fh * 0.80
	px, py := fw*0.12, sigY
	for i := 1; i <= 60; i++ {
		t := float64(i) / 60
		nx := fw*0.12 + fw*0.34*t
		ny := sigY - math.Sin(t*13)*fh*0.035*(0.5+0.5*math.Sin(t*3.1)) - fh*0.02*t
		c.stroke(px, py, nx, ny, fw*0.005, inkDark)
		px, py = nx, ny
	}

	// バーコード
	bx := fw * 0.62
	for bx < fw*0.90 {
		bw := fw * (0.002 + rnd.Float64()*0.006)
		c.rect(bx, fh*0.74, bx+bw, fh*0.86, inkDark)
		bx += bw + fw*(0.002+rnd.Float64()*0.005)
	}

	img := c.resolve()
	addNoise(img, rnd, 3)
	return img
}

// textBar は文字列 1 行を表す帯。実フォントを使わずに文字の密度を模す。
func textBar(c *canvas, x, y, w, h float64, col color.RGBA) {
	// 1 本の帯ではなく細かい塊に割ることで、実際の文字に近い高周波成分が出る。
	cx := x
	for cx < x+w {
		cw := h * (0.35 + 0.45*float64(int(cx*7)%5)/5)
		if cx+cw > x+w {
			cw = x + w - cx
		}
		c.rect(cx, y, cx+cw, y+h, col)
		cx += cw + h*0.22
	}
}

func frame(c *canvas, x0, y0, x1, y1, t float64, col color.RGBA) {
	c.rect(x0, y0, x1, y0+t, col)
	c.rect(x0, y1-t, x1, y1, col)
	c.rect(x0, y0, x0+t, y1, col)
	c.rect(x1-t, y0, x1, y1, col)
}

// figure は全身の人物を引きで捉えた構図。人物の背丈が画面の高さの約半分になる。
// 頭部は上半分に入るのでマスクで隠れ、脚・床は下半分に残って鮮明さの基準になる。
func figure(w, h int) *image.RGBA {
	rnd := rand.New(rand.NewSource(3))
	c := newCanvas(w, h)
	fw, fh := float64(w), float64(h)

	// 壁と床
	c.verticalGradient(backdropTop, backdropBot)
	floorY := fh * 0.80
	c.rect(0, floorY, fw, fh, lerp(deskTop, deskBot, 0.35))

	// 全身の寸法。頭身で各部を決める。
	feetY := floorY
	bodyH := fh * 0.50
	topY := feetY - bodyH
	headH := bodyH / 7
	headRY := headH / 2
	headRX := headRY * 0.78
	cx := fw * 0.5

	// 足元の影
	c.ellipse(cx, feetY+headH*0.10, headH*1.1, headH*0.16, clothShadow)

	shoulderY := topY + headH*1.25
	hipY := topY + bodyH*0.52

	// 脚
	legW := headH * 0.46
	for _, sx := range []float64{-1, 1} {
		lx := cx + sx*legW*0.62
		c.roundRect(lx-legW/2, hipY-headH*0.2, lx+legW/2, feetY, legW*0.4, clothShadow)
		c.ellipse(lx, feetY, legW*0.62, headH*0.15, inkDark) // 靴
	}

	// 胴
	c.roundRect(cx-headH*0.70, shoulderY, cx+headH*0.70, hipY+headH*0.1, headH*0.32, clothing)

	// 腕
	armW := headH * 0.30
	for _, sx := range []float64{-1, 1} {
		ax := cx + sx*headH*0.92
		c.roundRect(ax-armW/2, shoulderY, ax+armW/2, hipY+headH*0.25, armW*0.5, clothing)
		c.ellipse(ax, hipY+headH*0.32, armW*0.55, armW*0.6, skin) // 手
	}

	// 首と頭
	c.rect(cx-headRX*0.35, topY+headH*0.85, cx+headRX*0.35, shoulderY+headH*0.05, skinShadow)
	headCY := topY + headRY
	c.ellipse(cx, headCY-headRY*0.14, headRX*1.14, headRY*1.02, hair)
	c.ellipseFrom(cx, headCY, headRX, headRY, headCY-headRY*0.45, skin)

	// 顔は引きなので目と口だけ。作り込まない。
	for _, sx := range []float64{-1, 1} {
		c.ellipse(cx+sx*headRX*0.38, headCY-headRY*0.05, headRX*0.13, headRY*0.11, pupil)
	}
	c.ellipse(cx, headCY+headRY*0.45, headRX*0.26, headRY*0.09, lips)

	img := c.resolve()
	addNoise(img, rnd, 4)
	return img
}
