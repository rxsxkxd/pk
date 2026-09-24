package paramgen

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// このファイルは、生成する CloudFormation YAML の**スカラーの書き方を Ruby の YAML.dump
// （Psych + libyaml）と揃える**ためのものである。以前は Ruby で生成しており、
// examples/ のゴールデンファイルと、すでに適用済みのテンプレートがその書式で残っている。
// 書式が変わると値が同じでも差分レビューが読みにくくなるため、Psych の判定を移植する。
//
// Psych は文字列を次の順で判定する（Psych::Visitors::YAMLTree#visit_String）。
//
//  1. y / Y / n / N                         → 二重引用符
//  2. 先頭が単語構成文字以外で、" を含まない → 二重引用符（例: "*:mysql_native_password"）
//  3. 素のまま書くと文字列以外に読まれる     → 単一引用符（例: '1'、'ON'、'2010-09-09'）
//  4. それ以外                               → 素のまま。ただし libyaml が素のままでは
//     書けないと判断すれば（": " を含む、前後の空白など）単一引用符
//
// 改行を含む値と 80 文字を超える値は、Psych なら複数行の書式や折り返しになるが、
// パラメータ値では現れないため扱わない（二重引用符 1 行で書く。YAML としての値は同じ）。

// yamlScalar は値を 1 つの YAML スカラーとして書く。
func yamlScalar(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case bool:
		return strconv.FormatBool(typed)
	case int:
		return strconv.Itoa(typed)
	case int64:
		return strconv.FormatInt(typed, 10)
	case float64:
		// Ruby の Float#to_s に合わせる（1.0 は 1.0、1.5 は 1.5）。
		text := strconv.FormatFloat(typed, 'f', -1, 64)
		if !strings.Contains(text, ".") {
			text += ".0"
		}
		return text
	case string:
		return yamlString(typed)
	}
	return yamlString(stringOf(value))
}

func yamlString(s string) string {
	switch {
	case strings.Contains(strings.TrimSuffix(s, "\n"), "\n"):
		return doubleQuoted(s)
	case s == "<<":
		// マージキーと取り違えないよう、Psych は型タグを付けて書く。
		return "!!str '<<'"
	case s == "y" || s == "Y" || s == "n" || s == "N":
		return doubleQuoted(s)
	case s != "" && !isWordRune([]rune(s)[0]) && !strings.Contains(s, `"`):
		return doubleQuoted(s)
	case !tokenizesAsString(s) || leadingZeroWithEightOrNine.MatchString(s):
		return singleQuoted(s)
	case plainAllowed(s):
		return s
	}
	return singleQuoted(s)
}

var leadingZeroWithEightOrNine = regexp.MustCompile(`^0[0-7]*[89]`)

// isWordRune は Ruby の [[:word:]]（文字・数字・結合文字・連結句読点）に相当する。
func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.IsMark(r) || unicode.Is(unicode.Pc, r) || unicode.IsNumber(r)
}

func singleQuoted(s string) string {
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return doubleQuoted(s)
		}
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func doubleQuoted(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\t':
			b.WriteString(`\t`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r < 0x20 || r == 0x7f {
				fmt.Fprintf(&b, `\x%02X`, r)
				continue
			}
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// plainAllowed は libyaml（yaml_emitter_analyze_scalar）が block 文脈で素のまま書けると
// 判断するかを返す。
func plainAllowed(s string) bool {
	if s == "" {
		return false
	}
	runes := []rune(s)
	if runes[0] == ' ' || runes[len(runes)-1] == ' ' {
		return false
	}
	if strings.HasPrefix(s, "---") || strings.HasPrefix(s, "...") {
		return false
	}
	for i, r := range runes {
		followedByBlank := i+1 >= len(runes) || runes[i+1] == ' ' || runes[i+1] == '\t'
		precededByBlank := i == 0 || runes[i-1] == ' ' || runes[i-1] == '\t'
		switch {
		case i == 0 && strings.ContainsRune("#,[]{}&*!|>'\"%@`", r):
			return false
		case i == 0 && (r == '?' || r == ':' || r == '-') && followedByBlank:
			return false
		case r == ':' && followedByBlank:
			return false
		case r == '#' && precededByBlank:
			return false
		case r == '\t' || r < 0x20 || r == 0x7f || r == 0xFEFF:
			return false
		}
	}
	return true
}

// Psych::ScalarScanner の正規表現（integer は既定の LEGACY 版）。
var (
	stringLike    = regexp.MustCompile(`^[^\d.:-]?[\p{L}\p{M}_\s!@#$%^&*(){}<>|/\\~;=]+`)
	notYTONF      = regexp.MustCompile(`(?i)^[^ytonf~]`)
	nullWord      = regexp.MustCompile(`(?i)^null$`)
	trueWord      = regexp.MustCompile(`(?i)^(yes|true|on)$`)
	falseWord     = regexp.MustCompile(`(?i)^(no|false|off)$`)
	timePattern   = regexp.MustCompile(`^-?\d{4}-\d{1,2}-\d{1,2}(?:[Tt]|\s+)\d{1,2}:\d\d:\d\d(?:\.\d*)?(?:\s*(?:Z|[-+]\d{1,2}:?(?:\d\d)?))?$`)
	datePattern   = regexp.MustCompile(`^(\d{4})-(1[012]|0\d|\d)-([12]\d|3[01]|0\d|\d)$`)
	infPattern    = regexp.MustCompile(`(?i)^[-+]?\.inf$`)
	nanPattern    = regexp.MustCompile(`(?i)^\.nan$`)
	symbolPattern = regexp.MustCompile(`^:.`)
	sexagesimal   = regexp.MustCompile(`^[-+]?[0-9][0-9_]*(:[0-5]?[0-9]){1,2}(\.[0-9_]*)?$`)
	floatPattern  = regexp.MustCompile(`^(?:[-+]?([0-9][0-9_,]*)?\.[0-9]*([eE][-+][0-9]+)?)$`)
	bareDot       = regexp.MustCompile(`^[-+]?\.$`)
	integerLegacy = regexp.MustCompile(`^(?:[-+]?0b[0-1_,]+|[-+]?0[0-7_,]+|[-+]?(?:0|[1-9](?:[0-9]|,[0-9]|_[0-9])*)|[-+]?0x[0-9a-fA-F_,]+)$`)
)

// tokenizesAsString は、素のまま書いた値を Psych が文字列として読み戻すかを返す
// （Psych::ScalarScanner#tokenize が String を返すか）。
func tokenizesAsString(s string) bool {
	switch {
	case s == "":
		return false // nil になる
	case stringLike.MatchString(s):
		if len([]rune(s)) > 5 || notYTONF.MatchString(s) {
			return true
		}
		return !(s == "~" || nullWord.MatchString(s) || trueWord.MatchString(s) || falseWord.MatchString(s))
	case timePattern.MatchString(s):
		return false // 解釈できない日時は文字列に戻るが、パラメータ値では現れない
	case datePattern.MatchString(s):
		parts := datePattern.FindStringSubmatch(s)
		_, err := time.Parse("2006-1-2", parts[1]+"-"+parts[2]+"-"+parts[3])
		return err != nil // 実在しない日付は文字列のまま
	case infPattern.MatchString(s), nanPattern.MatchString(s), symbolPattern.MatchString(s), sexagesimal.MatchString(s):
		return false
	case floatPattern.MatchString(s):
		return bareDot.MatchString(s)
	case integerLegacy.MatchString(s):
		return false
	}
	return true
}
