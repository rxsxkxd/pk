package ticket

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"regexp"
	"testing"
	"time"
)

func TestGenerateVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../testdata/ticketcode.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			Now      string `json:"now"`
			Random   string `json:"random"`
			Suffix   string `json:"suffix"`
			Expected string `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}

	for _, c := range vectors.Cases {
		t.Run(c.Expected, func(t *testing.T) {
			now, err := time.Parse(time.RFC3339, c.Now)
			if err != nil {
				t.Fatal(err)
			}
			rnd, err := hex.DecodeString(c.Random)
			if err != nil {
				t.Fatal(err)
			}
			g := &Generator{Suffix: c.Suffix, Now: func() time.Time { return now }, Rand: bytes.NewReader(rnd)}

			got, err := g.Generate()
			if err != nil {
				t.Fatal(err)
			}
			if got.Code != c.Expected {
				t.Errorf("code = %q, want %q", got.Code, c.Expected)
			}
			if _, offset := got.IssuedAt.Zone(); offset != 9*60*60 {
				t.Errorf("issuedAt offset = %d, want JST", offset)
			}
		})
	}
}

func TestGenerateRandomShape(t *testing.T) {
	re := regexp.MustCompile(`^\d{14}[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}TQR$`)
	g, err := NewGenerator("TQR")
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for range 1000 {
		got, err := g.Generate()
		if err != nil {
			t.Fatal(err)
		}
		if !re.MatchString(got.Code) {
			t.Fatalf("unexpected code shape %q", got.Code)
		}
		if seen[got.Code] {
			t.Fatalf("duplicate code %q", got.Code)
		}
		seen[got.Code] = true
	}
}

func TestGenerateRandomError(t *testing.T) {
	g := &Generator{Suffix: "TQR", Now: time.Now, Rand: bytes.NewReader([]byte{1, 2})}
	if _, err := g.Generate(); err == nil {
		t.Fatal("expected error when random source is short")
	}
}

func TestNewGeneratorRejectsBadSuffix(t *testing.T) {
	for _, s := range []string{"", "has-hyphen", "has space", "日本語", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"} {
		if _, err := NewGenerator(s); err == nil {
			t.Errorf("NewGenerator(%q) = nil error", s)
		}
	}
}
