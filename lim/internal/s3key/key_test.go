package s3key

import (
	"strings"
	"testing"
)

func layout() Layout {
	return Layout{Prefix: "masking", OriginalInfix: "original", MaskedInfix: "v1"}
}

func TestBuildOriginalAndMasked(t *testing.T) {
	p := Parts{X: "tenant-a", Y: "2026-09", Z: "front", N: "id.jpg"}

	orig, err := layout().Original(p)
	if err != nil {
		t.Fatal(err)
	}
	if want := "masking/tenant-a/2026-09/original/front/id.jpg"; orig != want {
		t.Errorf("Original = %q, want %q", orig, want)
	}

	masked, err := layout().Masked(p)
	if err != nil {
		t.Fatal(err)
	}
	if want := "masking/tenant-a/2026-09/v1/front/id.jpg"; masked != want {
		t.Errorf("Masked = %q, want %q", masked, want)
	}
}

func TestParseRoundTrip(t *testing.T) {
	l := layout()
	want := Parts{X: "tenant-a", Y: "2026-09", Z: "front", N: "id.jpg"}

	key, err := l.Original(want)
	if err != nil {
		t.Fatal(err)
	}
	got, infix, err := l.Parse(key)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("Parse = %+v, want %+v", got, want)
	}
	if infix != "original" {
		t.Errorf("infix = %q, want original", infix)
	}
}

func TestParseRejectsMalformedKeys(t *testing.T) {
	tests := []struct {
		name string
		key  string
	}{
		{"階層が足りない", "masking/x/y/original/name.jpg"},
		{"階層が多い", "masking/x/y/original/z/sub/name.jpg"},
		{"プレフィックスが違う", "other/x/y/original/z/name.jpg"},
		{"空の階層", "masking/x//original/z/name.jpg"},
		{"末尾がスラッシュ", "masking/x/y/original/z/"},
		{"空文字", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, _, err := layout().Parse(tt.key); err == nil {
				t.Errorf("Parse(%q) should fail", tt.key)
			}
		})
	}
}

func TestBuildRejectsInjectedSeparators(t *testing.T) {
	// 変数は呼び出し側から来る。キーを別の場所へ向ける細工を通さないこと。
	tests := []struct {
		name  string
		parts Parts
	}{
		{"スラッシュで階層を増やす", Parts{X: "a/b", Y: "y", Z: "z", N: "n.jpg"}},
		{"上の階層を指す", Parts{X: "..", Y: "y", Z: "z", N: "n.jpg"}},
		{"カレントを指す", Parts{X: "x", Y: ".", Z: "z", N: "n.jpg"}},
		{"空文字", Parts{X: "", Y: "y", Z: "z", N: "n.jpg"}},
		{"ファイル名にスラッシュ", Parts{X: "x", Y: "y", Z: "z", N: "sub/n.jpg"}},
		{"改行", Parts{X: "x\n", Y: "y", Z: "z", N: "n.jpg"}},
		{"前後の空白", Parts{X: " x", Y: "y", Z: "z", N: "n.jpg"}},
		{"長すぎる", Parts{X: strings.Repeat("a", 256), Y: "y", Z: "z", N: "n.jpg"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := layout().Original(tt.parts); err == nil {
				t.Errorf("Original(%+v) should fail", tt.parts)
			}
		})
	}
}

func TestBuildAcceptsRealisticNames(t *testing.T) {
	// 日本語やスペースを含む名前は S3 のキーとして正当なので通す。
	ok := []Parts{
		{X: "tenant-a", Y: "2026-09-14", Z: "front", N: "id.jpg"},
		{X: "テナント", Y: "年度", Z: "表面", N: "身分証 1.jpg"},
		{X: "a.b", Y: "c_d", Z: "e-f", N: "g+h.png"},
	}
	for _, p := range ok {
		if _, err := layout().Original(p); err != nil {
			t.Errorf("Original(%+v) = %v, want no error", p, err)
		}
	}
}

func TestLayoutValidate(t *testing.T) {
	if err := layout().Validate(); err != nil {
		t.Errorf("Validate() = %v, want nil", err)
	}

	bad := []struct {
		name string
		l    Layout
	}{
		{"prefix が空", Layout{Prefix: "", OriginalInfix: "original", MaskedInfix: "v1"}},
		{"infix が空", Layout{Prefix: "masking", OriginalInfix: "", MaskedInfix: "v1"}},
		{"infix にスラッシュ", Layout{Prefix: "masking", OriginalInfix: "a/b", MaskedInfix: "v1"}},
		// 同じだと出力が原本を上書きし、自分自身を再度トリガする。
		{"原本とマスク済みが同じ", Layout{Prefix: "masking", OriginalInfix: "v1", MaskedInfix: "v1"}},
	}
	for _, tt := range bad {
		t.Run(tt.name, func(t *testing.T) {
			if err := tt.l.Validate(); err == nil {
				t.Errorf("Validate() should fail for %+v", tt.l)
			}
		})
	}
}
