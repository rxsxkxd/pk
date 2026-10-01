package signer

import (
	"encoding/json"
	"os"
	"testing"
)

func TestSignVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../testdata/signature.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			Salt       string `json:"salt"`
			TicketCode string `json:"ticketCode"`
			Sig        string `json:"sig"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}

	for _, c := range vectors.Cases {
		t.Run(c.TicketCode, func(t *testing.T) {
			s, err := New(c.Salt, "")
			if err != nil {
				t.Fatal(err)
			}
			if got := s.Sign(c.TicketCode); got != c.Sig {
				t.Errorf("Sign = %q, want %q", got, c.Sig)
			}
			if !s.Verify(c.TicketCode, c.Sig) {
				t.Error("Verify rejected a valid signature")
			}
		})
	}
}

func TestVerify(t *testing.T) {
	old, _ := New("old-salt", "")
	cur, _ := New("new-salt", "")
	rotating, _ := New("new-salt", "old-salt")
	code := "20261001-7K3QX9MZ2P"
	oldSig := old.Sign(code)

	tests := []struct {
		name string
		s    *Signer
		code string
		sig  string
		want bool
	}{
		{"current salt", rotating, code, cur.Sign(code), true},
		{"previous salt during rotation", rotating, code, oldSig, true},
		{"previous salt after rotation", cur, code, oldSig, false},
		{"other code", cur, "20261001-0000000000", cur.Sign(code), false},
		{"empty", cur, code, "", false},
		{"truncated", cur, code, cur.Sign(code)[:21], false},
		{"tampered", cur, code, "A" + cur.Sign(code)[1:], cur.Sign(code)[0] == 'A'},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.s.Verify(tt.code, tt.sig); got != tt.want {
				t.Errorf("Verify = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestNewRequiresSalt(t *testing.T) {
	if _, err := New("", "x"); err == nil {
		t.Fatal("expected error for empty salt")
	}
}
