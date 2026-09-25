package paramgen

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"rds-mysql-upgrade/tools/internal/awscli"
)

const example = "../../../examples/mysql84-parameter-generation"
const rules = "../../../config/mysql80-to-84-parameter-rules.yml"

// Ruby の YAML.dump（Psych 5 / libyaml）が実際に書いた形。移行前に Ruby で採取した。
var psychExpected = []struct{ value, yaml string }{
	{"ROW", "ROW"},
	{"MIXED", "MIXED"},
	{"1", "'1'"},
	{"0", "'0'"},
	{"67108864", "'67108864'"},
	{"ON", "'ON'"},
	{"OFF", "'OFF'"},
	{"on", "'on'"},
	{"Yes", "'Yes'"},
	{"no", "'no'"},
	{"y", "\"y\""},
	{"N", "\"N\""},
	{"true", "'true'"},
	{"false", "'false'"},
	{"null", "'null'"},
	{"~", "\"~\""},
	{"*:mysql_native_password", "\"*:mysql_native_password\""},
	{"{DBInstanceClassMemory*3/4}", "\"{DBInstanceClassMemory*3/4}\""},
	{"STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION", "STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION"},
	{"utf8mb4", "utf8mb4"},
	{"utf8mb4_0900_ai_ci", "utf8mb4_0900_ai_ci"},
	{"/rdsdbdata/tmp", "\"/rdsdbdata/tmp\""},
	{"2010-09-09", "'2010-09-09'"},
	{"2010-02-30", "2010-02-30"},
	{"2010-9-9", "'2010-9-9'"},
	{"1.5", "'1.5'"},
	{".5", "\".5\""},
	{"1e3", "1e3"},
	{"1.0e+3", "'1.0e+3'"},
	{"0x1F", "'0x1F'"},
	{"0o17", "0o17"},
	{"017", "'017'"},
	{"018", "'018'"},
	{"09", "'09'"},
	{"1_000", "'1_000'"},
	{"1,000", "'1,000'"},
	{"-1", "\"-1\""},
	{"+1", "\"+1\""},
	{"12:30", "'12:30'"},
	{"12:30:45", "'12:30:45'"},
	{".inf", "\".inf\""},
	{"-.inf", "\"-.inf\""},
	{".nan", "\".nan\""},
	{":sym", "\":sym\""},
	{"a: b", "'a: b'"},
	{"a:b", "a:b"},
	{"abc:", "'abc:'"},
	{"a #b", "'a #b'"},
	{"a#b", "a#b"},
	{"# comment", "\"# comment\""},
	{"- item", "\"- item\""},
	{"-1x", "\"-1x\""},
	{" leading", "\" leading\""},
	{"trailing ", "'trailing '"},
	{"it's", "it's"},
	{"say \"hi\"", "say \"hi\""},
	{"a|b", "a|b"},
	{"<<", "!!str '<<'"},
	{"---", "\"---\""},
	{"...", "\"...\""},
	{"日本語の値", "日本語の値"},
	{"値:あり", "値:あり"},
	{"SYSTEM", "SYSTEM"},
	{"0.5", "'0.5'"},
	{"00", "'00'"},
	{"0b101", "'0b101'"},
	{"8a", "8a"},
	{"a8", "a8"},
	{"1.2.3", "1.2.3"},
}

func TestYAMLScalarMatchesPsych(t *testing.T) {
	for _, tc := range psychExpected {
		if got := yamlScalar(tc.value); got != tc.yaml {
			t.Errorf("%q: %s（Psych は %s）", tc.value, got, tc.yaml)
		}
	}
	// ルールの値が YAML の数値・真偽なら、テンプレートにもその型で書く（Ruby と同じ）。
	for value, want := range map[any]string{100: "100", true: "true", 1.5: "1.5", 2.0: "2.0"} {
		if got := yamlScalar(value); got != want {
			t.Errorf("%v: %s（期待 %s）", value, got, want)
		}
	}
}

// ゴールデンファイル（examples/mysql84-parameter-generation/output）と一字一句一致すること。
func TestGenerateMatchesGolden(t *testing.T) {
	out := t.TempDir()
	// ルールの表記はレポートに載るので、リポジトリ直下から相対パスで渡す（実運用と同じ）。
	wd, _ := os.Getwd()
	root, _ := filepath.Abs("../../..")
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	result, err := Generate(Options{InputDir: "examples/mysql84-parameter-generation/input", OutputDir: out,
		System: "example", Environment: "production", RulesPath: "config/mysql80-to-84-parameter-rules.yml"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Generated != 6 || result.Review != 1 || result.Blocked != 0 {
		t.Errorf("件数が違う: %+v", result)
	}
	for _, name := range []string{"mysql84-parameter-group.yaml", "mysql80-to-mysql84-parameter-report.md"} {
		got, _ := os.ReadFile(filepath.Join(out, name))
		want, _ := os.ReadFile(filepath.Join("examples/mysql84-parameter-generation/output", name))
		if string(got) != string(want) {
			t.Errorf("%s がゴールデンと違う。examples/ を更新するなら差分をレビューすること", name)
		}
	}
}

// 例題を複製して 1 ファイルを書き換え、生成する。
func generateWith(t *testing.T, file string, change func(map[string]any)) (*Result, string) {
	t.Helper()
	in, out := t.TempDir(), t.TempDir()
	entries, _ := os.ReadDir(filepath.Join(example, "input"))
	for _, entry := range entries {
		content, _ := os.ReadFile(filepath.Join(example, "input", entry.Name()))
		if entry.Name() == file {
			var document map[string]any
			_ = json.Unmarshal(content, &document)
			change(document)
			content, _ = json.Marshal(document)
		}
		_ = os.WriteFile(filepath.Join(in, entry.Name()), content, 0o644)
	}
	result, err := Generate(Options{InputDir: in, OutputDir: out, System: "s", Environment: "e", RulesPath: rules})
	if err != nil {
		t.Fatal(err)
	}
	report, _ := os.ReadFile(result.ReportPath)
	return result, string(report)
}

func userParameters(d map[string]any) []any { return d["Parameters"].([]any) }

func TestBranches(t *testing.T) {
	// 8.4 で変更不可のパラメータは生成しない（生成不可）。
	result, _ := generateWith(t, "mysql84-default-parameters.json", func(d map[string]any) {
		for _, p := range d["EngineDefaults"].(map[string]any)["Parameters"].([]any) {
			if p.(map[string]any)["ParameterName"] == "max_allowed_packet" {
				p.(map[string]any)["IsModifiable"] = false
			}
		}
	})
	if result.Blocked != 1 {
		t.Errorf("変更不可は生成不可になること: %+v", result)
	}
	// 値に依存するルールは、値が一致しなければ適用しない（authentication_policy を生成しない）。
	result, report := generateWith(t, "source-user-parameters.json", func(d map[string]any) {
		for _, p := range userParameters(d) {
			if p.(map[string]any)["ParameterName"] == "default_authentication_plugin" {
				p.(map[string]any)["ParameterValue"] = "caching_sha2_password"
			}
		}
	})
	template, _ := os.ReadFile(result.TemplatePath)
	if strings.Contains(string(template), "authentication_policy") || !strings.Contains(report, "適用条件（mysql_native_password）に該当しない") {
		t.Errorf("値が一致しないルールを適用した")
	}
	// ルールに無い user 定義は、8.4 に無ければ生成不可として検出する。
	result, _ = generateWith(t, "source-user-parameters.json", func(d map[string]any) {
		d["Parameters"] = append(userParameters(d), map[string]any{"ParameterName": "query_cache_size", "ParameterValue": "1"})
	})
	if result.Blocked != 1 {
		t.Errorf("8.4 に無い user 定義は生成不可になること: %+v", result)
	}
}

func TestReadRulesKeepsOrder(t *testing.T) {
	list, err := ReadRules(rules)
	if err != nil || len(list) == 0 {
		t.Fatalf("%v", err)
	}
	if list[0].Name != "binlog_format" {
		t.Errorf("記述順を保つこと: 先頭が %s", list[0].Name)
	}
}

func TestCollect(t *testing.T) {
	bin := t.TempDir()
	log := filepath.Join(bin, "calls.log")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + log + "\necho '{}'\n"
	_ = os.WriteFile(filepath.Join(bin, "aws"), []byte(script), 0o755)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	out := t.TempDir()
	err := Collect(CollectOptions{Client: awscli.Client{Region: "r"}, SourceParameterGroup: "pg-80", DBInstanceID: "blue-1",
		OutputDir: out, Now: func() time.Time { return time.Date(2026, 9, 25, 0, 0, 0, 0, time.UTC) }})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"source-parameter-group.json", "source-user-parameters.json", "source-system-parameters.json",
		"mysql80-default-parameters.json", "mysql84-default-parameters.json", "source-db-instance.json"} {
		if _, err := os.Stat(filepath.Join(out, name)); err != nil {
			t.Errorf("%s が無い", name)
		}
	}
	metadata, _ := os.ReadFile(filepath.Join(out, "metadata.json"))
	if string(metadata) != `{"source_parameter_group":"pg-80","collected_at":"2026-09-25T00:00:00Z"}`+"\n" {
		t.Errorf("metadata.json: %s", metadata)
	}
	calls, _ := os.ReadFile(log)
	if strings.Count(string(calls), "\n") != 6 || !strings.Contains(string(calls), "--source user") {
		t.Errorf("呼び出しが違う:\n%s", calls)
	}
}
