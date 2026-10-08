package ticket

// Ticket codes: {YYYYMMDDHHmmss}{UUIDv4, 32 lowercase hex digits without hyphens}{fixed suffix}, generated
// without shared state (DESIGN.md 4). The suffix is a fixed string from Parameter Store (1-32 letters/digits).

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"regexp"
	"time"
)

// Fixed offset instead of time.LoadLocation: provided.al2023 does not ship tzdata.
var jst = time.FixedZone("JST", 9*60*60)

// SuffixPattern is the allowed fixed suffix: it goes into URL paths and QR codes as is.
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

// NewGenerator makes a generator with the fixed suffix, which must match SuffixPattern.
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

// uuidV4 reads 16 random bytes and returns a version 4 (random) UUID as 32 lowercase hex digits, without
// hyphens (RFC 9562: version 4 in the high nibble of byte 6, variant 10 in the high bits of byte 8).
func uuidV4(r io.Reader) (string, error) {
	var b [16]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", fmt.Errorf("read random: %w", err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return hex.EncodeToString(b[:]), nil
}
