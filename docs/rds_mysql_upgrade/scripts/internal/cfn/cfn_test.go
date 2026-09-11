package cfn

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTemplate(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "pg.yaml")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return path
}

func TestIntrinsicKey(t *testing.T) {
	cases := map[string]string{
		"!Ref":       "Ref",
		"!Condition": "Condition",
		"!Sub":       "Fn::Sub",
		"!GetAtt":    "Fn::GetAtt",
		// YAML の型タグは組み込み関数ではない。
		"!!str": "",
		"!!map": "",
		"":      "",
	}
	for tag, want := range cases {
		if got := IntrinsicKey(tag); got != want {
			t.Errorf("IntrinsicKey(%q) = %q, want %q", tag, got, want)
		}
	}
}

// 短縮記法をそのまま Unmarshal するとタグが捨てられ、!Ref Workers が
// "Workers" という文字列に化ける。正規化して読めていることを確かめる。
func TestReadDBParameterGroupNormalizesShorthand(t *testing.T) {
	path := writeTemplate(t, `
Resources:
  Other:
    Type: AWS::SNS::Topic
  ParameterGroup:
    Type: AWS::RDS::DBParameterGroup
    Properties:
      Family: mysql8.4
      Parameters:
        time_zone: UTC
        max_connections: '512'
        innodb_buffer_pool_size: !Ref BufferPoolSize
        character_set_server: !Sub '${CharacterSet}'
        some_list: [a, b]
`)
	group, err := ReadDBParameterGroup(path)
	if err != nil {
		t.Fatalf("ReadDBParameterGroup: %v", err)
	}

	if value, resolved, _ := group.Parameter("time_zone"); !resolved || value != "UTC" {
		t.Errorf("time_zone = %q resolved=%v", value, resolved)
	}
	if value, resolved, _ := group.Parameter("max_connections"); !resolved || value != "512" {
		t.Errorf("max_connections = %q resolved=%v", value, resolved)
	}
	// 組み込み関数の項目は実値が決まらない。比較対象から外し、種類を示す。
	if _, resolved, intrinsic := group.Parameter("innodb_buffer_pool_size"); resolved || intrinsic != "Ref" {
		t.Errorf("innodb_buffer_pool_size resolved=%v intrinsic=%q", resolved, intrinsic)
	}
	if _, resolved, intrinsic := group.Parameter("character_set_server"); resolved || intrinsic != "Fn::Sub" {
		t.Errorf("character_set_server resolved=%v intrinsic=%q", resolved, intrinsic)
	}
	if _, resolved, intrinsic := group.Parameter("some_list"); resolved || intrinsic != "Fn::*" {
		t.Errorf("some_list resolved=%v intrinsic=%q", resolved, intrinsic)
	}
	// 宣言されていないパラメータは、値なし・組み込み関数なしで返る。
	if _, resolved, intrinsic := group.Parameter("absent"); resolved || intrinsic != "" {
		t.Errorf("absent resolved=%v intrinsic=%q", resolved, intrinsic)
	}
}

func TestReadDBParameterGroupRejectsBadTemplates(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    string
	}{
		{"Resources が無い", "Description: nothing\n", "Resources が見つからない"},
		{"パラメータグループが無い", "Resources:\n  Topic:\n    Type: AWS::SNS::Topic\n",
			"AWS::RDS::DBParameterGroup が見つからない"},
		{"最上位がマッピングではない", "- a\n- b\n", "最上位がマッピングではない"},
		{"YAML が壊れている", "Resources: [\n", "YAML を解析できない"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			_, err := ReadDBParameterGroup(writeTemplate(t, testCase.content))
			if err == nil {
				t.Fatal("ReadDBParameterGroup succeeded, want failure")
			}
			if !strings.Contains(err.Error(), testCase.want) {
				t.Errorf("error = %v, want it to contain %q", err, testCase.want)
			}
		})
	}
	if _, err := ReadDBParameterGroup(filepath.Join(t.TempDir(), "absent.yaml")); err == nil {
		t.Error("missing file accepted, want failure")
	}
}

// リポジトリの共通 fixture（examples/cfn-shorthand/）でも同じ解釈になることを確かめる。
// Ruby 版・インライン Python 版と足並みを揃えるための入口である。
func TestReadDBParameterGroupOnRepositoryFixture(t *testing.T) {
	path := "../../../examples/cfn-shorthand/mysql84-parameter-group-shorthand.yaml"
	if _, err := os.Stat(path); err != nil {
		t.Skipf("fixture が無い: %v", err)
	}
	group, err := ReadDBParameterGroup(path)
	if err != nil {
		t.Fatalf("ReadDBParameterGroup: %v", err)
	}
	if len(group.Declared) == 0 {
		t.Error("fixture should declare at least one resolved parameter")
	}
	if len(group.Unresolved) == 0 {
		t.Error("fixture should declare at least one intrinsic parameter")
	}
	for name, intrinsic := range group.Unresolved {
		if _, alsoDeclared := group.Declared[name]; alsoDeclared {
			t.Errorf("%s appears in both Declared and Unresolved", name)
		}
		if intrinsic == "" {
			t.Errorf("%s has an empty intrinsic kind", name)
		}
	}
}
