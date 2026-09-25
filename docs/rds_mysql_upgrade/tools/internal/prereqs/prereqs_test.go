package prereqs

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"rds-mysql-upgrade/tools/internal/awscli"
)

const example = "../../../examples/blue-green-prereqs"

// ゴールデンファイル（examples/blue-green-prereqs/output）と一字一句一致すること。
func TestReportMatchesGolden(t *testing.T) {
	evaluation, err := Evaluate(filepath.Join(example, "input"))
	if err != nil {
		t.Fatal(err)
	}
	golden, err := os.ReadFile(filepath.Join(example, "output", "prereqs-evaluation-report.md"))
	if err != nil {
		t.Fatal(err)
	}
	if got := evaluation.Report(); got != string(golden) {
		t.Fatalf("ゴールデンと違う。examples/ を更新するなら差分をレビューすること:\n%s", got)
	}
}

// 例題を複製し、1 項目だけ書き換えて判定が変わることを確かめる。
func mutate(t *testing.T, file string, change func(map[string]any)) string {
	t.Helper()
	dir := t.TempDir()
	entries, _ := os.ReadDir(filepath.Join(example, "input"))
	for _, entry := range entries {
		content, _ := os.ReadFile(filepath.Join(example, "input", entry.Name()))
		if entry.Name() == file {
			var document map[string]any
			if err := json.Unmarshal(content, &document); err != nil {
				t.Fatal(err)
			}
			change(document)
			content, _ = json.Marshal(document)
		}
		if err := os.WriteFile(filepath.Join(dir, entry.Name()), content, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func status(t *testing.T, dir, item string) string {
	t.Helper()
	evaluation, err := Evaluate(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, result := range evaluation.Results {
		if strings.HasPrefix(result.Item, item) {
			return result.Status
		}
	}
	t.Fatalf("%s が無い", item)
	return ""
}

func instance(document map[string]any) map[string]any {
	return document["DBInstances"].([]any)[0].(map[string]any)
}

func TestVerdicts(t *testing.T) {
	for _, tc := range []struct {
		name, file, item, want string
		change                 func(map[string]any)
	}{
		{"バックアップ無効は STOP", "db-instance.json", "0-1-01", "STOP",
			func(d map[string]any) { instance(d)["BackupRetentionPeriod"] = 0 }},
		{"既定以外のオプショングループは STOP", "db-instance.json", "0-1-03", "STOP",
			func(d map[string]any) {
				instance(d)["OptionGroupMemberships"] = []any{map[string]any{"OptionGroupName": "custom"}}
			}},
		{"MEMCACHED は STOP", "option-group.json", "0-1-04", "STOP",
			func(d map[string]any) {
				d["OptionGroupsList"].([]any)[0].(map[string]any)["Options"] = []any{map[string]any{"OptionName": "MEMCACHED"}}
			}},
		{"適用待ちは STOP", "db-instance.json", "0-1-05", "STOP",
			func(d map[string]any) {
				instance(d)["DBParameterGroups"] = []any{map[string]any{"ParameterApplyStatus": "pending-reboot"}}
			}},
		{"空き容量が無ければ REVIEW", "free-storage-space.json", "0-1-09", "REVIEW",
			func(d map[string]any) { d["Datapoints"] = []any{} }},
		{"IAM DB 認証は REVIEW", "db-instance.json", "0-1-14", "REVIEW",
			func(d map[string]any) { instance(d)["IAMDatabaseAuthenticationEnabled"] = true }},
	} {
		if got := status(t, mutate(t, tc.file, tc.change), tc.item); got != tc.want {
			t.Errorf("%s: %s（期待 %s）", tc.name, got, tc.want)
		}
	}
}

func TestMissingFileIsReported(t *testing.T) {
	_, err := Evaluate(t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "Missing metadata.json") {
		t.Fatalf("収集ファイルの欠落を伝えること: %v", err)
	}
}

// 偽の aws で収集し、全ファイルが揃うこと・同じ API を二度叩かないことを確かめる。
func TestCollect(t *testing.T) {
	bin := t.TempDir()
	log := filepath.Join(bin, "calls.log")
	input, _ := filepath.Abs(filepath.Join(example, "input"))
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + log + "\ncase \"$*\" in\n" +
		"  *\"describe-db-instances --db-instance-identifier\"*) cat " + input + "/db-instance.json ;;\n" +
		"  *describe-db-instances*) cat " + input + "/all-db-instances.json ;;\n" +
		"  *describe-db-proxies*) echo '{\"DBProxies\":[{\"DBProxyName\":\"p1\"}]}' ;;\n" +
		"  *) echo '{}' ;;\nesac\n"
	if err := os.WriteFile(filepath.Join(bin, "aws"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	out := t.TempDir()
	err := Collect(CollectOptions{
		Client: awscli.Client{Region: "ap-northeast-1"}, DBInstanceID: "blue-1",
		TargetEngineVersion: "8.4.9", OutputDir: out,
		Now: func() time.Time { return time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC) },
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"db-instance.json", "all-db-instances.json", "db-parameters.json", "option-group.json",
		"orderable-classes.json", "db-proxies.json", "db-proxy-targets-0.json", "integrations.json",
		"free-storage-space.json", "metadata.json"} {
		if _, err := os.Stat(filepath.Join(out, name)); err != nil {
			t.Errorf("%s が無い", name)
		}
	}
	metadata, _ := os.ReadFile(filepath.Join(out, "metadata.json"))
	if string(metadata) != `{"db_instance_id":"blue-1","target_engine_version":"8.4.9","collected_at":"2026-09-25T12:00:00Z"}`+"\n" {
		t.Errorf("metadata.json: %s", metadata)
	}
	calls, _ := os.ReadFile(log)
	text := string(calls)
	if strings.Contains(text, "--query") {
		t.Errorf("--query で二度引きしないこと:\n%s", text)
	}
	if !strings.Contains(text, "--start-time 2026-09-25T11:00:00Z --end-time 2026-09-25T12:00:00Z") {
		t.Errorf("空き容量は直近 1 時間を見ること:\n%s", text)
	}
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if !strings.HasPrefix(line, "--region ap-northeast-1 ") || strings.Contains(line, "--profile") {
			t.Errorf("--region だけを前置すること: %s", line)
		}
	}
}

// 例題を複製し、MySQL 側のファイルを入れ替える（nil なら置かない）。
func withMySQLSide(t *testing.T, state, check string) *Evaluation {
	t.Helper()
	dir := mutate(t, "metadata.json", func(map[string]any) {})
	for name, content := range map[string]string{"blue-mysql-state.json": state, "blue-upgrade-check.json": check} {
		path := filepath.Join(dir, name)
		_ = os.Remove(path)
		if content != "" {
			if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	evaluation, err := Evaluate(dir)
	if err != nil {
		t.Fatal(err)
	}
	return evaluation
}

func TestMySQLSideOmittedIsExplicit(t *testing.T) {
	evaluation := withMySQLSide(t, "", "")
	report := evaluation.Report()
	for _, want := range []string{
		"## MySQL 側の収集結果",
		"**省略した。**入力ディレクトリに `blue-mysql-state.json` が無い（`collect_blue_mysql_state` を実行していない）。",
		"**省略した。**入力ディレクトリに `blue-upgrade-check.json` が無い（`collect_blue_upgrade_check` を実行していない）。",
	} {
		if !strings.Contains(report, want) {
			t.Errorf("レポートに %q が無い", want)
		}
	}
	if !strings.Contains(evaluation.Summary(), "blue-mysql-state.json=省略, blue-upgrade-check.json=省略") {
		t.Errorf("標準出力にも省略を示すこと:\n%s", evaluation.Summary())
	}
}

func TestMySQLSideRendersResults(t *testing.T) {
	state := `{"collected_at":"T","host":"blue","port":3306,"version":"8.0.39","binlog_format":"MIXED",
	  "replica_status":[{"Source_Host":"external.example","Source_Port":"3306","Replica_IO_Running":"Yes","Replica_SQL_Running":"Yes","Last_IO_Error":"a|b"}],
	  "non_innodb_tables":[]}`
	check := `{"collected_at":"T","host":"blue","port":3306,"target_version":"8.4.9","error_count":1,"warning_count":1,"notice_count":0,
	  "report":{"serverVersion":"8.0.39","summary":"1 errors","checksPerformed":[
	    {"id":"a","title":"A","status":"OK","detectedProblems":[{"level":"Warning","dbObject":"w","description":"warn"}]},
	    {"id":"b","title":"B","status":"OK","detectedProblems":[{"level":"Error","dbObject":"e","description":"err"}]}],
	  "manualChecks":[{"id":"m","title":"Manual"}]}}`
	evaluation := withMySQLSide(t, state, check)
	report := evaluation.Report()
	for _, want := range []string{
		"| SHOW REPLICA STATUS | 1 行 |",
		"|  | external.example | 3306 | Yes | Yes |  | a\|b |  |", // セル内の | はエスケープする
		"**InnoDB 以外のテーブル**（0-2。ユーザースキーマのみ。MyISAM は binlog レプリケーションで整合性が保証されない）\n\nなし。",
		"| Error / Warning / Notice | 1 / 1 / 0 |",
		"- Manual（`m`）",
	} {
		if !strings.Contains(report, want) {
			t.Errorf("レポートに %q が無い", want)
		}
	}
	if strings.Index(report, "| Error | `b` |") > strings.Index(report, "| Warning | `a` |") {
		t.Errorf("Error を Warning より先に並べること")
	}
	// 外部レプリカがあれば 0-1-06 は STOP、チェッカーの Error があれば 0-3 も STOP。
	for item, want := range map[string]string{"0-1-06": "STOP", "0-3": "STOP"} {
		if got := resultOf(t, evaluation, item).Status; got != want {
			t.Errorf("%s: %s（期待 %s）", item, got, want)
		}
	}
}

func resultOf(t *testing.T, evaluation *Evaluation, item string) Result {
	t.Helper()
	for _, result := range evaluation.Results {
		if strings.HasPrefix(result.Item, item+" ") {
			return result
		}
	}
	t.Fatalf("%s が無い", item)
	return Result{}
}

func TestMySQLSideVerdicts(t *testing.T) {
	state := func(binlog, tables string) string {
		return `{"collected_at":"2026-09-17T00:05:00Z","host":"h","version":"8.0.39","binlog_format":"` + binlog +
			`","replica_status":[],"non_innodb_tables":[` + tables + `]}`
	}
	check := func(errors, warnings int) string {
		return fmt.Sprintf(`{"collected_at":"2026-09-17T00:10:00Z","host":"restored","target_version":"8.4.9","error_count":%d,"warning_count":%d,"notice_count":0,"report":{}}`, errors, warnings)
	}
	for _, tc := range []struct {
		name, state, check, item, want, detail string
	}{
		{"未収集なら 0-1-06 は REVIEW", "", "", "0-1-06", "REVIEW", "collect_blue_mysql_state"},
		{"未収集なら 0-2 は REVIEW", "", "", "0-2", "REVIEW", "未収集"},
		{"未収集なら 0-3 は REVIEW", "", "", "0-3", "REVIEW", "collect_blue_upgrade_check"},
		{"レプリカでなければ 0-1-06 は PASS", state("MIXED", ""), "", "0-1-06", "PASS", "空"},
		{"MyISAM があれば 0-2 は STOP", state("MIXED", `{"TABLE_SCHEMA":"app","TABLE_NAME":"t","ENGINE":"MyISAM"}`), "", "0-2", "STOP", "MyISAM=1"},
		{"MyISAM 以外だけなら 0-2 は REVIEW", state("MIXED", `{"TABLE_SCHEMA":"app","TABLE_NAME":"t","ENGINE":"MEMORY"}`), "", "0-2", "REVIEW", "MEMORY=1"},
		{"Error が無く Warning があれば 0-3 は REVIEW", "", check(0, 3), "0-3", "REVIEW", "Warning=3"},
		{"どちらも無ければ 0-3 は PASS", "", check(0, 0), "0-3", "PASS", "Error=0"},
		{"実効値がパラメータグループと違えば 0-1-02 は REVIEW", state("ROW", ""), "", "0-1-02", "REVIEW", "食い違っている"},
	} {
		result := resultOf(t, withMySQLSide(t, tc.state, tc.check), tc.item)
		if result.Status != tc.want || !strings.Contains(result.Detail, tc.detail) {
			t.Errorf("%s: %s %q", tc.name, result.Status, result.Detail)
		}
	}
}

func TestNotes(t *testing.T) {
	// 例題の Blue のエンドポイントと、それ以外の接続先。
	blue := "example-service-production-mysql80.xxxxxxxxxxxx.ap-northeast-1.rds.amazonaws.com"
	for _, tc := range []struct {
		name, state, check, want string
	}{
		{"欠けた収集があれば未収集として判定したと書く", "", "", "MySQL 側の収集が欠けている"},
		{"収集日時が離れていれば再収集を促す", `{"collected_at":"2026-01-01T00:00:00Z","host":"` + blue + `","replica_status":[],"non_innodb_tables":[]}`, "", "時間以上離れている"},
		{"状態の接続先が Blue でなければ確認を促す", `{"collected_at":"2026-09-17T00:05:00Z","host":"other","replica_status":[],"non_innodb_tables":[]}`, "", "接続先（`other`）が対象 Blue のエンドポイント"},
		{"チェッカーを本番に対して実行していれば注意する", "", `{"collected_at":"2026-09-17T00:10:00Z","host":"` + blue + `","report":{}}`, "対象 Blue（本番）に対して実行している"},
		{"RDS 固有の項目は Shell で出ないことを常に書く", "", "", "PrePatchCompatibility.log"},
	} {
		if report := withMySQLSide(t, tc.state, tc.check).Report(); !strings.Contains(report, tc.want) {
			t.Errorf("%s: %q が無い", tc.name, tc.want)
		}
	}
	// 項目ごとの補足は全項目に載る。
	evaluation := withMySQLSide(t, "", "")
	report := evaluation.Report()
	for _, result := range evaluation.Results {
		key := strings.Fields(result.Item)[0]
		if guidanceByItem[key].Condition == "" || !strings.Contains(report, "| "+result.Status+" | "+escapeCell(result.Item)+" | "+escapeCell(guidanceByItem[key].Condition)) {
			t.Errorf("%s の補足が無い", result.Item)
		}
	}
}

func TestMySQLSidePartial(t *testing.T) {
	evaluation := withMySQLSide(t, `{"version":"8.0.39","replica_status":[],"non_innodb_tables":[]}`, "")
	report := evaluation.Report()
	if !strings.Contains(report, "| MySQL バージョン | 8.0.39 |") || !strings.Contains(report, "`collect_blue_upgrade_check` を実行していない") {
		t.Errorf("片方だけあるときは、ある方を載せて無い方を省略と示すこと")
	}
	if !strings.Contains(evaluation.Summary(), "blue-mysql-state.json=あり, blue-upgrade-check.json=省略") {
		t.Errorf("標準出力: %s", evaluation.Summary())
	}
}
