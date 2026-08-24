package s3key

import (
	"strings"
	"testing"
)

func withPrefix() Layout {
	return Layout{Prefix: "masking", OriginalInfix: "no-masked", MaskedInfix: "masked"}
}

func noPrefix() Layout {
	return Layout{OriginalInfix: "no-masked", MaskedInfix: "masked"}
}

func sample() Parts {
	return Parts{TenantID: "t-001", Date: "2026-09-14", LocationID: "loc-12", EntryID: "e-98765"}
}

func TestBuildWithAndWithoutPrefix(t *testing.T) {
	tests := []struct {
		name     string
		layout   Layout
		original string
		masked   string
	}{
		{
			name:     "prefix あり",
			layout:   withPrefix(),
			original: "masking/t-001/no-masked/2026-09-14/loc-12/e-98765",
			masked:   "masking/t-001/masked/2026-09-14/loc-12/e-98765",
		},
		{
			name:     "prefix なし",
			layout:   noPrefix(),
			original: "t-001/no-masked/2026-09-14/loc-12/e-98765",
			masked:   "t-001/masked/2026-09-14/loc-12/e-98765",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := tt.layout.Original(sample())
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.original {
				t.Errorf("Original = %q, want %q", got, tt.original)
			}
			got, err = tt.layout.Masked(sample())
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.masked {
				t.Errorf("Masked = %q, want %q", got, tt.masked)
			}
		})
	}
}

func TestParseRoundTrip(t *testing.T) {
	for _, l := range []Layout{withPrefix(), noPrefix()} {
		key, err := l.Original(sample())
		if err != nil {
			t.Fatal(err)
		}
		got, infix, err := l.Parse(key)
		if err != nil {
			t.Fatalf("Parse(%q): %v", key, err)
		}
		if got != sample() {
			t.Errorf("Parse(%q) = %+v, want %+v", key, got, sample())
		}
		if infix != "no-masked" {
			t.Errorf("infix = %q, want no-masked", infix)
		}
	}
}

func TestParseDistinguishesInfix(t *testing.T) {
	// 再帰ループ防止は infix の判定に依存している。
	l := withPrefix()
	masked, _ := l.Masked(sample())
	_, infix, err := l.Parse(masked)
	if err != nil {
		t.Fatal(err)
	}
	if infix != "masked" {
		t.Errorf("infix = %q, want masked", infix)
	}
}

func TestParseRejectsMalformedKeys(t *testing.T) {
	tests := []struct {
		name   string
		layout Layout
		key    string
	}{
		{"階層が足りない", withPrefix(), "masking/t-001/no-masked/2026-09-14/loc-12"},
		{"階層が多い", withPrefix(), "masking/t-001/no-masked/2026-09-14/loc-12/sub/e-1"},
		{"プレフィックスが違う", withPrefix(), "other/t-001/no-masked/2026-09-14/loc-12/e-1"},
		{"prefix なし設定にプレフィックス付きキー", noPrefix(), "masking/t-001/no-masked/2026-09-14/loc-12/e-1"},
		{"prefix あり設定にプレフィックスなしキー", withPrefix(), "t-001/no-masked/2026-09-14/loc-12/e-1"},
		{"空の階層", withPrefix(), "masking/t-001//2026-09-14/loc-12/e-1"},
		{"末尾がスラッシュ", noPrefix(), "t-001/no-masked/2026-09-14/loc-12/"},
		{"空文字", noPrefix(), ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, _, err := tt.layout.Parse(tt.key); err == nil {
				t.Errorf("Parse(%q) should fail", tt.key)
			}
		})
	}
}

func TestBuildRejectsInjectedSeparators(t *testing.T) {
	// 変数は呼び出し側から来る。キーを別の場所へ向ける細工を通さないこと。
	base := sample()
	tests := []struct {
		name  string
		parts Parts
	}{
		{"スラッシュで階層を増やす", Parts{TenantID: "a/b", Date: base.Date, LocationID: base.LocationID, EntryID: base.EntryID}},
		{"上の階層を指す", Parts{TenantID: "..", Date: base.Date, LocationID: base.LocationID, EntryID: base.EntryID}},
		{"infix を差し替える", Parts{TenantID: base.TenantID, Date: "../masked", LocationID: base.LocationID, EntryID: base.EntryID}},
		{"空のテナント", Parts{Date: base.Date, LocationID: base.LocationID, EntryID: base.EntryID}},
		{"空のエントリ", Parts{TenantID: base.TenantID, Date: base.Date, LocationID: base.LocationID}},
		{"改行", Parts{TenantID: "t\n", Date: base.Date, LocationID: base.LocationID, EntryID: base.EntryID}},
		{"前後の空白", Parts{TenantID: " t", Date: base.Date, LocationID: base.LocationID, EntryID: base.EntryID}},
		{"長すぎる", Parts{TenantID: strings.Repeat("a", 256), Date: base.Date, LocationID: base.LocationID, EntryID: base.EntryID}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for _, l := range []Layout{withPrefix(), noPrefix()} {
				if _, err := l.Original(tt.parts); err == nil {
					t.Errorf("Original(%+v) should fail", tt.parts)
				}
			}
		})
	}
}

func TestBuildAcceptsRealisticValues(t *testing.T) {
	ok := []Parts{
		sample(),
		{TenantID: "tenant_a", Date: "20260914", LocationID: "1", EntryID: "01JABCDEF"},
		// 拡張子が付いていても付いていなくても通す。
		{TenantID: "t", Date: "2026-09-14", LocationID: "l", EntryID: "e-1.jpg"},
		// UUID 形式
		{TenantID: "9f1c", Date: "2026-09-14", LocationID: "loc", EntryID: "1e5a0b2c-3d4e-5f60-7a8b-9c0d1e2f3a4b"},
	}
	for _, p := range ok {
		for _, l := range []Layout{withPrefix(), noPrefix()} {
			if _, err := l.Original(p); err != nil {
				t.Errorf("Original(%+v) = %v, want no error", p, err)
			}
		}
	}
}

func TestLayoutValidate(t *testing.T) {
	for _, l := range []Layout{withPrefix(), noPrefix()} {
		if err := l.Validate(); err != nil {
			t.Errorf("Validate() = %v, want nil", err)
		}
	}

	bad := []struct {
		name string
		l    Layout
	}{
		{"infix が空", Layout{Prefix: "masking", OriginalInfix: "", MaskedInfix: "masked"}},
		{"マスク側の infix が空", Layout{Prefix: "masking", OriginalInfix: "no-masked"}},
		{"infix にスラッシュ", Layout{OriginalInfix: "a/b", MaskedInfix: "masked"}},
		{"prefix にスラッシュ", Layout{Prefix: "a/b", OriginalInfix: "no-masked", MaskedInfix: "masked"}},
		// 同じだと出力が原本を上書きし、自分自身を再度トリガする。
		{"原本とマスク済みが同じ", Layout{OriginalInfix: "masked", MaskedInfix: "masked"}},
	}
	for _, tt := range bad {
		t.Run(tt.name, func(t *testing.T) {
			if err := tt.l.Validate(); err == nil {
				t.Errorf("Validate() should fail for %+v", tt.l)
			}
		})
	}
}
