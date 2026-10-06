package ticket

// Ticket codes: {YYYYMMDDHHmmss}-{suffix}, generated without shared state (DESIGN.md 4).

import (
	"crypto/rand"
	"fmt"
	"io"
	"time"
)

// Crockford Base32 (no I, L, O, U).
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// Fixed offset instead of time.LoadLocation: provided.al2023 does not ship tzdata.
var jst = time.FixedZone("JST", 9*60*60)

type Ticket struct {
	Code     string
	IssuedAt time.Time // JST
}

type Generator struct {
	SuffixLength int
	Now          func() time.Time
	Rand         io.Reader
}

func NewGenerator(suffixLength int) *Generator {
	return &Generator{SuffixLength: suffixLength, Now: time.Now, Rand: rand.Reader}
}

func (g *Generator) Generate() (Ticket, error) {
	buf := make([]byte, g.SuffixLength)
	if _, err := io.ReadFull(g.Rand, buf); err != nil {
		return Ticket{}, fmt.Errorf("read random: %w", err)
	}
	// 256 is a multiple of 32, so the low 5 bits of each byte are uniform.
	suffix := make([]byte, len(buf))
	for i, b := range buf {
		suffix[i] = alphabet[b&31]
	}
	now := g.Now().In(jst)
	return Ticket{Code: now.Format("20060102150405") + "-" + string(suffix), IssuedAt: now}, nil
}
