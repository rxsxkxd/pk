package ticket

// チケットコード: {YYYYMMDDHHmmss}{UUIDv4、ハイフンなしの小文字 16 進 32 桁}{固定サフィックス}。共有状態なしで
// 生成する(DESIGN.md 4)。サフィックスは Parameter Store の固定文字列(英数字 1〜32 文字)。

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"regexp"
	"time"
)

// time.LoadLocation ではなく固定オフセットを使う: provided.al2023 には tzdata が含まれないため。
var jst = time.FixedZone("JST", 9*60*60)

// SuffixPattern は許可される固定サフィックス: URL のパスと QR コードにそのまま入る。
var SuffixPattern = regexp.MustCompile(`^[A-Za-z0-9]{1,32}$`)

type Ticket struct {
	Code     string
	IssuedAt time.Time // JST
}

type Generator struct {
	Suffix string
	Now    func() time.Time
	Rand   io.Reader
}

// NewGenerator は固定サフィックスを持つ生成器を作る。サフィックスは SuffixPattern に一致しなければならない。
func NewGenerator(suffix string) (*Generator, error) {
	if !SuffixPattern.MatchString(suffix) {
		return nil, fmt.Errorf("ticket code suffix must be 1-32 letters or digits, got %q", suffix)
	}
	return &Generator{Suffix: suffix, Now: time.Now, Rand: rand.Reader}, nil
}

func (g *Generator) Generate() (Ticket, error) {
	id, err := uuidV4(g.Rand)
	if err != nil {
		return Ticket{}, err
	}
	now := g.Now().In(jst)
	return Ticket{Code: now.Format("20060102150405") + id + g.Suffix, IssuedAt: now}, nil
}

// uuidV4 は 16 バイトの乱数を読み、バージョン 4(ランダム)の UUID をハイフンなしの小文字 16 進 32 桁で返す
// (RFC 9562: バイト 6 の上位ニブルにバージョン 4、バイト 8 の上位ビットにバリアント 10)。
func uuidV4(r io.Reader) (string, error) {
	var b [16]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", fmt.Errorf("read random: %w", err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return hex.EncodeToString(b[:]), nil
}
