package mysqlcli

import (
	"context"
	"strings"
	"testing"
)

var target = Target{Host: "blue.example", Port: 3306, User: "checker", SSLCA: "/certs/rds/global-bundle.pem"}

const secret = "s3cret-password"

func TestArgsNeverCarryPassword(t *testing.T) {
	for _, args := range [][]string{MySQLArgs(target, "SELECT 1"), MySQLShellArgs(target, "8.4.9")} {
		joined := strings.Join(args, " ")
		// --passwords-from-stdin は値を取らないので許す。値つきの指定だけを拒む。
		if strings.Contains(joined, secret) || strings.Contains(joined, "--password=") || strings.Contains(joined, " -p") {
			t.Fatalf("引数にパスワードが載っている: %s", joined)
		}
		if !strings.Contains(joined, "--ssl-mode=VERIFY_CA") || !strings.Contains(joined, "--ssl-ca="+target.SSLCA) {
			t.Fatalf("VERIFY_CA になっていない: %s", joined)
		}
	}
}

func TestMySQLArgsStartWithNoDefaults(t *testing.T) {
	// --no-defaults は先頭以外では mysql に無視される。
	if args := MySQLArgs(target, "SELECT 1"); args[0] != "--no-defaults" {
		t.Fatalf("先頭が --no-defaults でない: %v", args)
	}
}

func TestValidateRequiresCA(t *testing.T) {
	missing := target
	missing.SSLCA = ""
	if err := missing.Validate(); err == nil || !strings.Contains(err.Error(), "--ssl-ca") {
		t.Fatalf("CA 未指定を検出できていない: %v", err)
	}
}

const variablesXML = `<?xml version="1.0"?>

<resultset statement="SELECT ..." xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <row>
	<field name="version">8.0.40</field>
	<field name="binlog_format">MIXED</field>
  </row>
</resultset>
`

const emptyXML = `<?xml version="1.0"?>

<resultset statement="SHOW REPLICA STATUS" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
</resultset>
`

const tablesXML = `<?xml version="1.0"?>

<resultset statement="SELECT ..." xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <row>
	<field name="TABLE_SCHEMA">app</field>
	<field name="TABLE_NAME">legacy &amp; &lt;old&gt;</field>
	<field name="ENGINE">MyISAM</field>
  </row>
  <row>
	<field name="TABLE_SCHEMA">app</field>
	<field name="TABLE_NAME">broken</field>
	<field name="ENGINE" xsi:nil="true" />
  </row>
</resultset>
`

func TestParseXML(t *testing.T) {
	rows, err := ParseXML([]byte(tablesXML))
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("2 行を期待: %d", len(rows))
	}
	if got := *rows[0]["TABLE_NAME"]; got != "legacy & <old>" {
		t.Fatalf("エスケープの復元が違う: %q", got)
	}
	if rows[1]["ENGINE"] != nil {
		t.Fatalf("NULL が nil になっていない: %q", *rows[1]["ENGINE"])
	}
	empty, err := ParseXML([]byte(emptyXML))
	if err != nil || len(empty) != 0 {
		t.Fatalf("空の結果セットは空の並び: %v %v", empty, err)
	}
}

// fakeRunner はクエリ文字列から応答を選ぶ。渡された環境変数と標準入力を記録する。
type fakeRunner struct {
	responses map[string]Result
	env       [][]string
	stdin     []string
}

func (f *fakeRunner) run(_ context.Context, _ string, args, env []string, stdin string) (Result, error) {
	f.env = append(f.env, env)
	f.stdin = append(f.stdin, stdin)
	joined := strings.Join(args, " ")
	for key, result := range f.responses {
		if strings.Contains(joined, key) {
			return result, nil
		}
	}
	return Result{ExitCode: 1, Stderr: []byte("unexpected: " + joined)}, nil
}

func TestCollectState(t *testing.T) {
	fake := &fakeRunner{responses: map[string]Result{
		"@@GLOBAL.binlog_format": {Stdout: []byte(variablesXML)},
		"SHOW REPLICA STATUS":    {Stdout: []byte(emptyXML)},
		"information_schema":     {Stdout: []byte(tablesXML)},
	}}
	state, err := CollectState(context.Background(), fake.run, "mysql", target, secret)
	if err != nil {
		t.Fatal(err)
	}
	if state.Version != "8.0.40" || state.BinlogFormat != "MIXED" {
		t.Fatalf("変数の取り出しが違う: %+v", state)
	}
	if len(state.ReplicaStatus) != 0 || len(state.NonInnoDBTables) != 2 {
		t.Fatalf("行数が違う: %+v", state)
	}
	for _, env := range fake.env {
		if len(env) != 1 || env[0] != "MYSQL_PWD="+secret {
			t.Fatalf("パスワードは MYSQL_PWD だけで渡す: %v", env)
		}
	}
}

func TestCollectStateFailsOnAnyQuery(t *testing.T) {
	fake := &fakeRunner{responses: map[string]Result{
		"@@GLOBAL.binlog_format": {Stdout: []byte(variablesXML)},
		"SHOW REPLICA STATUS": {ExitCode: 1,
			Stderr: []byte("ERROR 1227 (42000): Access denied; you need the REPLICATION CLIENT privilege")},
	}}
	_, err := CollectState(context.Background(), fake.run, "mysql", target, secret)
	if err == nil || !strings.Contains(err.Error(), "REPLICATION CLIENT") {
		t.Fatalf("権限不足を理由付きで返すこと: %v", err)
	}
}

const checkerJSON = `{
    "serverAddress": "blue.example:3306",
    "serverVersion": "8.0.40 - Source distribution",
    "targetVersion": "8.4.9",
    "errorCount": 1,
    "warningCount": 3,
    "noticeCount": 0,
    "summary": "1 errors were found. Please correct these issues before upgrading to avoid compatibility issues.",
    "checksPerformed": []
}`

func TestExtractJSONSkipsPrompt(t *testing.T) {
	// 実測の形: 入力促しは色付きで、改行せずに JSON が続く。
	out := "\x1b[1mPlease provide the password for 'checker@blue.example:3306': \x1b[0m" + checkerJSON + "\ntrailing noise {not json}\n"
	value, err := ExtractJSON([]byte(out))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(value), "{") || !strings.Contains(string(value), `"errorCount": 1`) {
		t.Fatalf("取り出しが違う: %s", value)
	}
	if _, err := ExtractJSON([]byte("ERROR: connection failed {x} {\"other\": 1}\n")); err == nil {
		t.Fatal("JSON が無ければ失敗すること")
	}
}

func TestCollectUpgradeCheckRecordsFindingsWithoutFailing(t *testing.T) {
	// 問題が見つかって mysqlsh が 0 以外で終わっても、JSON が取れれば収集は成功である。
	fake := &fakeRunner{responses: map[string]Result{
		"check-for-server-upgrade": {Stdout: []byte(checkerJSON), ExitCode: 1},
	}}
	check, err := CollectUpgradeCheck(context.Background(), fake.run, "mysqlsh", target, secret, "8.4.9")
	if err != nil {
		t.Fatal(err)
	}
	if check.ErrorCount != 1 || check.WarningCount != 3 || check.ShellExitCode != 1 {
		t.Fatalf("件数・終了コードの記録が違う: %+v", check)
	}
	if fake.stdin[0] != secret+"\n" || len(fake.env[0]) != 0 {
		t.Fatalf("mysqlsh へは標準入力だけで渡す: env=%v stdin=%q", fake.env[0], fake.stdin[0])
	}
}

func TestCollectUpgradeCheckFailsWithoutJSON(t *testing.T) {
	fake := &fakeRunner{responses: map[string]Result{
		"check-for-server-upgrade": {ExitCode: 1, Stderr: []byte("MySQL Error 2003: Can't connect")},
	}}
	_, err := CollectUpgradeCheck(context.Background(), fake.run, "mysqlsh", target, secret, "8.4.9")
	if err == nil || !strings.Contains(err.Error(), "Can't connect") {
		t.Fatalf("接続失敗を理由付きで返すこと: %v", err)
	}
}
