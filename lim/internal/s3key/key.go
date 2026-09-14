// Package s3key は入出力オブジェクトのキー構造を組み立て、また解釈する。
//
// キーは次の形に固定する。prefix は任意で、設定しなければ tid から始まる。
//
//	[<prefix>/]<tid>/<infix>/<date>/<lid>/<eid>
//
//	prefix … 共有バケット内でこのアプリが使うルート。Lambda 側で定義する（任意）
//	tid   … テナント ID。呼び出し側から受け取る
//	infix … 原本とマスク済みを分ける階層。Lambda 側で定義する（必須）
//	        既定は no-masked / masked
//	date  … 日付。呼び出し側から受け取る
//	lid   … ロケーション ID。呼び出し側から受け取る
//	eid   … エントリ ID。オブジェクト名にあたる。呼び出し側から受け取る
//
// 原本とマスク済みの違いは infix だけで、それ以外の変数は入出力で共通になる。
package s3key

import (
	"fmt"
	"strings"
)

// Parts は呼び出し側から受け取る変数。
type Parts struct {
	TenantID   string `json:"tenant_id"`
	Date       string `json:"date"`
	LocationID string `json:"location_id"`
	EntryID    string `json:"entry_id"`
}

// Layout は Lambda 側で定義する固定部分。
type Layout struct {
	Prefix        string // 共有バケット内のルート。空なら付けない
	OriginalInfix string // 原本の階層（必須）
	MaskedInfix   string // マスク済みの階層（必須）
}

// Validate は設定として成立しているかを確かめる。
func (l Layout) Validate() error {
	// prefix は任意。指定された場合だけ 1 階層分の名前として検証する。
	if l.Prefix != "" {
		if err := validSegment(l.Prefix); err != nil {
			return fmt.Errorf("KEY_PREFIX: %w", err)
		}
	}
	for _, f := range []struct{ name, value string }{
		{"ORIGINAL_INFIX", l.OriginalInfix},
		{"MASKED_INFIX", l.MaskedInfix},
	} {
		if err := validSegment(f.value); err != nil {
			return fmt.Errorf("%s: %w", f.name, err)
		}
	}
	if l.OriginalInfix == l.MaskedInfix {
		// 同じだと出力が原本を上書きし、さらに自分自身を再度トリガする。
		return fmt.Errorf("ORIGINAL_INFIX and MASKED_INFIX must differ (both %q)", l.MaskedInfix)
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
	seg := []string{p.TenantID, infix, p.Date, p.LocationID, p.EntryID}
	if l.Prefix != "" {
		seg = append([]string{l.Prefix}, seg...)
	}
	return strings.Join(seg, "/"), nil
}

// Parse はキーを解釈し、変数と infix を返す。形が合わないキーはエラーにする。
func (l Layout) Parse(key string) (Parts, string, error) {
	seg := strings.Split(key, "/")

	want := 5
	shape := "<tid>/<infix>/<date>/<lid>/<eid>"
	if l.Prefix != "" {
		want = 6
		shape = "<prefix>/" + shape
	}
	if len(seg) != want {
		return Parts{}, "", fmt.Errorf("key %q has %d segments, want %d (%s)", key, len(seg), want, shape)
	}
	if l.Prefix != "" {
		if seg[0] != l.Prefix {
			return Parts{}, "", fmt.Errorf("key %q does not start with the configured prefix %q", key, l.Prefix)
		}
		seg = seg[1:]
	}

	p := Parts{TenantID: seg[0], Date: seg[2], LocationID: seg[3], EntryID: seg[4]}
	if err := p.Validate(); err != nil {
		return Parts{}, "", fmt.Errorf("key %q: %w", key, err)
	}
	infix := seg[1]
	if err := validSegment(infix); err != nil {
		return Parts{}, "", fmt.Errorf("key %q: infix: %w", key, err)
	}
	return p, infix, nil
}

// Validate は変数が 1 階層分の名前として成立しているかを確かめる。
func (p Parts) Validate() error {
	for _, f := range []struct{ name, value string }{
		{"tenant_id", p.TenantID},
		{"date", p.Date},
		{"location_id", p.LocationID},
		{"entry_id", p.EntryID},
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
