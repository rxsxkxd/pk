// Package s3key は入出力オブジェクトのキー構造を組み立て、また解釈する。
//
// キーは次の 7 要素をスラッシュで連ねた形に固定する。
//
//	<bucket>/<prefix>/<x>/<y>/<infix>/<z>/<n>
//
//	prefix … 共有バケット内でこのアプリが使うルート。Lambda 側で定義する
//	x, y  … 呼び出し側から受け取る変数
//	infix … 原本とマスク済みを分ける階層。Lambda 側で定義する
//	z     … 呼び出し側から受け取る変数
//	n     … ファイル名。呼び出し側から受け取る
//
// 原本とマスク済みの違いは infix だけで、それ以外の変数は入出力で共通になる。
package s3key

import (
	"fmt"
	"strings"
)

// Parts は呼び出し側から受け取る変数。
type Parts struct {
	X string `json:"x"`
	Y string `json:"y"`
	Z string `json:"z"`
	N string `json:"n"`
}

// Layout は Lambda 側で定義する固定部分。
type Layout struct {
	Prefix        string // 共有バケット内のルート
	OriginalInfix string // 原本の階層
	MaskedInfix   string // マスク済みの階層（マスキングポリシー版）
}

// Validate は設定として成立しているかを確かめる。
func (l Layout) Validate() error {
	for _, f := range []struct{ name, value string }{
		{"KEY_PREFIX", l.Prefix},
		{"ORIGINAL_INFIX", l.OriginalInfix},
		{"MASKING_POLICY_VERSION", l.MaskedInfix},
	} {
		if err := validSegment(f.value); err != nil {
			return fmt.Errorf("%s: %w", f.name, err)
		}
	}
	if l.OriginalInfix == l.MaskedInfix {
		// 同じだと出力が原本を上書きし、さらに自分自身を再度トリガする。
		return fmt.Errorf("ORIGINAL_INFIX and MASKING_POLICY_VERSION must differ (both %q)", l.MaskedInfix)
	}
	return nil
}

// Original は原本のキーを組み立てる。
func (l Layout) Original(p Parts) (string, error) { return l.build(l.OriginalInfix, p) }

// Masked はマスク済みのキーを組み立てる。
func (l Layout) Masked(p Parts) (string, error) { return l.build(l.MaskedInfix, p) }

func (l Layout) build(infix string, p Parts) (string, error) {
	if err := p.Validate(); err != nil {
		return "", err
	}
	return strings.Join([]string{l.Prefix, p.X, p.Y, infix, p.Z, p.N}, "/"), nil
}

// Parse はキーを解釈し、変数と infix を返す。
// 形が合わないキーはエラーにする。
func (l Layout) Parse(key string) (Parts, string, error) {
	seg := strings.Split(key, "/")
	if len(seg) != 6 {
		return Parts{}, "", fmt.Errorf("key %q has %d segments, want 6 (<prefix>/<x>/<y>/<infix>/<z>/<n>)", key, len(seg))
	}
	if seg[0] != l.Prefix {
		return Parts{}, "", fmt.Errorf("key %q does not start with the configured prefix %q", key, l.Prefix)
	}
	p := Parts{X: seg[1], Y: seg[2], Z: seg[4], N: seg[5]}
	if err := p.Validate(); err != nil {
		return Parts{}, "", fmt.Errorf("key %q: %w", key, err)
	}
	infix := seg[3]
	if err := validSegment(infix); err != nil {
		return Parts{}, "", fmt.Errorf("key %q: infix: %w", key, err)
	}
	return p, infix, nil
}

// Validate は変数が 1 階層分の名前として成立しているかを確かめる。
func (p Parts) Validate() error {
	for _, f := range []struct{ name, value string }{
		{"x", p.X}, {"y", p.Y}, {"z", p.Z}, {"n", p.N},
	} {
		if err := validSegment(f.value); err != nil {
			return fmt.Errorf("%s: %w", f.name, err)
		}
	}
	return nil
}

// validSegment は 1 階層分の名前として使える文字列かを判定する。
//
// 変数は呼び出し側から来るため、キーを別の場所へ向けられないよう厳しめに見る。
// "a/b" を渡して階層を増やす、".." で上の階層を指す、空文字で階層を潰す、
// といった細工を通さない。
func validSegment(s string) error {
	switch {
	case s == "":
		return fmt.Errorf("must not be empty")
	case strings.Contains(s, "/"):
		return fmt.Errorf("must not contain a slash: %q", s)
	case s == "." || s == "..":
		return fmt.Errorf("must not be %q", s)
	case strings.HasPrefix(s, " ") || strings.HasSuffix(s, " "):
		return fmt.Errorf("must not have leading or trailing spaces: %q", s)
	case len(s) > 255:
		return fmt.Errorf("must be 255 bytes or shorter, got %d", len(s))
	case strings.ContainsAny(s, "\x00\r\n"):
		return fmt.Errorf("must not contain control characters: %q", s)
	}
	return nil
}
