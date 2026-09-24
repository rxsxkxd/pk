// Package mysqlcli は、成立条件チェックの MySQL 側の収集を担う。
//
// 成立条件チェックは 2 段階である。
//
//  1. AWS 側: collect_blue_green_prereqs.sh が AWS の読み取り API で集める
//  2. MySQL 側: 本パッケージが Blue へ接続して集める（AWS API では見えない項目）
//
// **MySQL への接続は mysql / mysqlsh コマンドを exec して行う。**ドライバを
// 組み込まないのは、成立条件チェックがローカル（compose の mysql コンテナ。両コマンド入り）
// で動く前提で、MySQL Shell のアップグレードチェッカーはそもそもコマンドとしてしか
// 使えないためである。2 つの収集を同じ接続規約（下記）で揃える。
//
// 接続規約:
//   - **パスワードをコマンド引数に載せない。**mysql へは環境変数 MYSQL_PWD、
//     mysqlsh へは標準入力（--passwords-from-stdin）で渡す
//   - TLS は --ssl-mode で選ぶ（下記の SSLModes）。**既定は VERIFY_CA**（証明書チェーンを
//     検証し、ホスト名は検証しない）。検証する 2 つのモードでは CA バンドルが必須
//   - mysql は --no-defaults で起動し、利用者の my.cnf に挙動を左右させない
//
// **判定はしない。**収集結果を JSON で書き出すだけで、合否は判定側が決める。
package mysqlcli

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// 出力ファイル名。collect_blue_green_prereqs.sh の出力先へ一緒に置き、
// 判定側が同じ --input-dir から読めるようにする。
const (
	StateFileName        = "blue-mysql-state.json"
	UpgradeCheckFileName = "blue-upgrade-check.json"
)

// DefaultSSLMode は --ssl-mode を指定しないときのモードである。
// 証明書チェーンを検証する（ホスト名は検証しない）。弱いモードは明示したときだけ使う。
const DefaultSSLMode = "VERIFY_CA"

// SSLModes は mysql / mysqlsh の --ssl-mode に渡せる値と、その意味である。
//
//	DISABLED         TLS を使わない（平文。強制的に TLS なし）
//	PREFERRED        サーバーが対応していれば TLS（任意。平文へ黙って落ちうる）
//	REQUIRED         TLS 必須。ただし証明書は検証しない
//	VERIFY_CA        TLS 必須。証明書チェーンを検証する（既定）
//	VERIFY_IDENTITY  TLS 必須。証明書チェーンとホスト名を検証する
//
// 検証する 2 つ（VERIFY_CA / VERIFY_IDENTITY）は --ssl-ca が必須で、
// 検証しない 3 つには --ssl-ca を渡せない（渡しても検証されず、指定の意図と食い違うため）。
var SSLModes = []string{"DISABLED", "PREFERRED", "REQUIRED", "VERIFY_CA", "VERIFY_IDENTITY"}

// Target は接続先である。パスワードはここに持たない（渡し方がコマンドごとに違うため）。
type Target struct {
	Host    string
	Port    int
	User    string
	SSLMode string // 空なら DefaultSSLMode
	SSLCA   string
}

// RegisterFlags は接続先のフラグ（--host / --port / --user / --ssl-mode / --ssl-ca）を登録する。
// MySQL へ接続するツールはすべてこれを使い、フラグの名前と意味を揃える。
func RegisterFlags(flags *flag.FlagSet, t *Target, hostUsage string) {
	flags.StringVar(&t.Host, "host", t.Host, hostUsage)
	flags.IntVar(&t.Port, "port", 3306, "接続ポート")
	flags.StringVar(&t.User, "user", t.User, "接続ユーザー")
	flags.StringVar(&t.SSLMode, "ssl-mode", DefaultSSLMode,
		"TLS の扱い: "+strings.Join(SSLModes, " / ")+"（VERIFY_* は --ssl-ca が必須）")
	flags.StringVar(&t.SSLCA, "ssl-ca", "", "CA バンドル（VERIFY_CA / VERIFY_IDENTITY のときだけ指定する）")
}

// VerifiesCertificate は、このモードがサーバー証明書を検証するかを返す。
func (t Target) VerifiesCertificate() bool {
	mode := t.mode()
	return mode == "VERIFY_CA" || mode == "VERIFY_IDENTITY"
}

// SecurityWarning は、証明書を検証しないモードのときに利用者へ出す警告を返す（検証するなら空）。
func (t Target) SecurityWarning() string {
	switch t.mode() {
	case "DISABLED":
		return "WARNING: --ssl-mode=DISABLED は TLS を使わない。パスワードと結果が平文で流れる。"
	case "PREFERRED":
		return "WARNING: --ssl-mode=PREFERRED はサーバー証明書を検証せず、TLS が使えなければ平文で接続する。"
	case "REQUIRED":
		return "WARNING: --ssl-mode=REQUIRED は暗号化するが、サーバー証明書を検証しない（接続先のなりすましを防げない）。"
	}
	return ""
}

func (t Target) mode() string {
	if t.SSLMode == "" {
		return DefaultSSLMode
	}
	return strings.ToUpper(t.SSLMode)
}

// Validate は必須項目と TLS の組み合わせを確かめる。
func (t Target) Validate() error {
	var missing []string
	if t.Host == "" {
		missing = append(missing, "--host")
	}
	if t.User == "" {
		missing = append(missing, "--user")
	}
	if len(missing) > 0 {
		return fmt.Errorf("%s は必須である", strings.Join(missing, ", "))
	}
	if t.Port <= 0 {
		return fmt.Errorf("--port が不正: %d", t.Port)
	}
	mode := t.mode()
	valid := false
	for _, candidate := range SSLModes {
		valid = valid || candidate == mode
	}
	if !valid {
		return fmt.Errorf("--ssl-mode が不正: %s（有効な値: %s）", t.SSLMode, strings.Join(SSLModes, ", "))
	}
	if t.VerifiesCertificate() && t.SSLCA == "" {
		return fmt.Errorf("--ssl-mode=%s には --ssl-ca が必要である（証明書を検証しないなら REQUIRED などを明示する）", mode)
	}
	if !t.VerifiesCertificate() && t.SSLCA != "" {
		return fmt.Errorf("--ssl-mode=%s では --ssl-ca を使わない（証明書を検証しないモードである）", mode)
	}
	return nil
}

// sslArgs は mysql / mysqlsh 共通の TLS 引数である。
func (t Target) sslArgs() []string {
	args := []string{"--ssl-mode=" + t.mode()}
	if t.SSLCA != "" {
		args = append(args, "--ssl-ca="+t.SSLCA)
	}
	return args
}

// Result はコマンド 1 回分の実行結果である。
type Result struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
}

// Runner はコマンドを実行する。テストでは差し替える。
// env は追加する環境変数（KEY=VALUE）、stdin は標準入力へ流す内容である。
type Runner func(ctx context.Context, name string, args, env []string, stdin string) (Result, error)

// ExecRunner は実際にコマンドを exec する Runner である。
// 終了コードが 0 以外でも error にはせず、Result.ExitCode で返す（解釈は呼び出し側が決める）。
func ExecRunner(ctx context.Context, name string, args, env []string, stdin string) (Result, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), env...)
	cmd.Stdin = strings.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	result := Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}
	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr):
		result.ExitCode = exitErr.ExitCode()
	default:
		// コマンドが見つからない・タイムアウトなど、終了コードを得られない失敗。
		return result, fmt.Errorf("%s を実行できなかった: %w", name, err)
	}
	return result, nil
}

// ---------------------------------------------------------------------------
// mysql コマンド
// ---------------------------------------------------------------------------

// MySQLArgs は mysql コマンドの引数を組み立てる。**パスワードは含めない**（MYSQL_PWD で渡す）。
// 出力は --xml にする。タブ区切り（--batch）は値の中の改行やタブをエスケープで表すため、
// 構造を持った XML の方が取り違えなく読める。NULL も xsi:nil で区別できる。
func MySQLArgs(t Target, query string) []string {
	args := []string{
		"--no-defaults", // 利用者の my.cnf を読まない。**先頭に置く必要がある**
		"--host=" + t.Host,
		"--port=" + strconv.Itoa(t.Port),
		"--user=" + t.User,
	}
	args = append(args, t.sslArgs()...)
	return append(args, "--connect-timeout=10", "--xml", "--execute="+query)
}

// Query は mysql コマンドで SQL を 1 本実行し、結果の行を返す。**読み取りの SQL だけを渡す。**
// パスワードは環境変数 MYSQL_PWD でだけ渡す。
func Query(ctx context.Context, run Runner, mysqlBin string, t Target, password, sql string) ([]Row, error) {
	result, err := run(ctx, mysqlBin, MySQLArgs(t, sql), []string{"MYSQL_PWD=" + password}, "")
	if err != nil {
		return nil, err
	}
	if result.ExitCode != 0 {
		return nil, fmt.Errorf("mysql の終了コード %d: %s", result.ExitCode, strings.TrimSpace(string(result.Stderr)))
	}
	return ParseXML(result.Stdout)
}

// Row は結果の 1 行である。値が NULL の列は nil になる。
type Row map[string]*string

type xmlResultSet struct {
	Rows []struct {
		Fields []struct {
			Name  string `xml:"name,attr"`
			Nil   string `xml:"http://www.w3.org/2001/XMLSchema-instance nil,attr"`
			Value string `xml:",chardata"`
		} `xml:"field"`
	} `xml:"row"`
}

// ParseXML は `mysql --xml` の出力（結果セット 1 つ）を行の並びにする。
// 行が無い結果セット（例: レプリカでないときの SHOW REPLICA STATUS）は空の並びを返す。
func ParseXML(data []byte) ([]Row, error) {
	var set xmlResultSet
	if err := xml.Unmarshal(data, &set); err != nil {
		return nil, fmt.Errorf("mysql --xml の出力を解釈できない: %w", err)
	}
	rows := make([]Row, 0, len(set.Rows))
	for _, r := range set.Rows {
		row := Row{}
		for _, f := range r.Fields {
			if f.Nil == "true" {
				row[f.Name] = nil
				continue
			}
			value := f.Value
			row[f.Name] = &value
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// 成立条件チェックで MySQL 側から取る項目。**読み取りだけで、設定を変更しない。**
var stateQueries = struct {
	variables, replicaStatus, nonInnoDB string
}{
	// binlog_format の実効値（0-1-02。パラメータグループの値と食い違うことがある）。
	variables: "SELECT @@GLOBAL.version AS version, @@GLOBAL.binlog_format AS binlog_format",
	// 外部 binlog レプリカでないこと（0-1-06。AWS API では確認できない）。
	// 要 REPLICATION CLIENT 権限。
	replicaStatus: "SHOW REPLICA STATUS",
	// ユーザースキーマに InnoDB 以外のテーブルが無いこと（移行ガイドの 0-2。MyISAM の棚卸し）。
	// mysql スキーマ等のシステムテーブルは対象外。
	nonInnoDB: "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE FROM information_schema.TABLES" +
		" WHERE TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB'" +
		" AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')" +
		" ORDER BY TABLE_SCHEMA, TABLE_NAME",
}

// State は mysql コマンドで集めた Blue の状態である（blue-mysql-state.json）。
type State struct {
	CollectedAt     string `json:"collected_at"`
	Host            string `json:"host"`
	Port            int    `json:"port"`
	Version         string `json:"version"`
	BinlogFormat    string `json:"binlog_format"`
	ReplicaStatus   []Row  `json:"replica_status"`
	NonInnoDBTables []Row  `json:"non_innodb_tables"`
}

// CollectState は mysql コマンドを 3 回実行して State を組み立てる。
// どれか 1 つでも失敗したら全体を失敗にする（欠けた収集結果で判定させないため）。
func CollectState(ctx context.Context, run Runner, mysqlBin string, t Target, password string) (*State, error) {
	query := func(label, sql string) ([]Row, error) {
		rows, err := Query(ctx, run, mysqlBin, t, password, sql)
		if err != nil {
			return nil, fmt.Errorf("%s の取得に失敗した（%w）", label, err)
		}
		return rows, nil
	}

	variables, err := query("バージョンと binlog_format", stateQueries.variables)
	if err != nil {
		return nil, err
	}
	if len(variables) != 1 {
		return nil, fmt.Errorf("バージョンと binlog_format: 1 行を期待したが %d 行だった", len(variables))
	}
	replica, err := query("SHOW REPLICA STATUS", stateQueries.replicaStatus)
	if err != nil {
		return nil, err
	}
	nonInnoDB, err := query("InnoDB 以外のテーブル", stateQueries.nonInnoDB)
	if err != nil {
		return nil, err
	}
	return &State{
		Host:            t.Host,
		Port:            t.Port,
		Version:         deref(variables[0]["version"]),
		BinlogFormat:    deref(variables[0]["binlog_format"]),
		ReplicaStatus:   replica,
		NonInnoDBTables: nonInnoDB,
	}, nil
}

func deref(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

// ---------------------------------------------------------------------------
// mysqlsh コマンド（MySQL Shell のアップグレードチェッカー）
// ---------------------------------------------------------------------------

// MySQLShellArgs は mysqlsh でアップグレードチェッカーを動かす引数を組み立てる。
// **パスワードは含めない**（--passwords-from-stdin で標準入力から渡す）。
func MySQLShellArgs(t Target, targetVersion string) []string {
	// --no-wizard は付けない。付けるとパスワードの入力促しごと抑止され、
	// 標準入力のパスワードが読まれずに「using password: NO」で失敗する（実測）。
	args := append([]string{"--passwords-from-stdin"}, t.sslArgs()...)
	return append(args,
		"--host="+t.Host,
		"--port="+strconv.Itoa(t.Port),
		"--user="+t.User,
		"--",
		"util", "check-for-server-upgrade",
		"--target-version="+targetVersion,
		"--output-format=JSON",
	)
}

// UpgradeCheck はアップグレードチェッカーの結果である（blue-upgrade-check.json）。
// Report はチェッカーの JSON をそのまま持つ。件数だけは判定側が引きやすいよう取り出す。
type UpgradeCheck struct {
	CollectedAt   string          `json:"collected_at"`
	Host          string          `json:"host"`
	Port          int             `json:"port"`
	TargetVersion string          `json:"target_version"`
	ShellExitCode int             `json:"shell_exit_code"`
	ErrorCount    int             `json:"error_count"`
	WarningCount  int             `json:"warning_count"`
	NoticeCount   int             `json:"notice_count"`
	Report        json.RawMessage `json:"report"`
}

// ExtractJSON は mysqlsh の標準出力からチェッカーの JSON を取り出す。
//
// --passwords-from-stdin のとき、mysqlsh は入力促し（色付きの
// "Please provide the password for ...: "）を**改行せずに**標準出力へ出し、
// その直後に JSON を続ける（実測）。そのため行頭とは限らない `{` ごとに
// 1 つの JSON 値として読めるかを試し、チェッカーの結果（errorCount を持つ
// オブジェクト）であるものを採る。
func ExtractJSON(stdout []byte) (json.RawMessage, error) {
	for offset := 0; offset < len(stdout); {
		index := bytes.IndexByte(stdout[offset:], '{')
		if index < 0 {
			break
		}
		start := offset + index
		var value json.RawMessage
		if err := json.NewDecoder(bytes.NewReader(stdout[start:])).Decode(&value); err == nil {
			var probe map[string]json.RawMessage
			if json.Unmarshal(value, &probe) == nil {
				if _, ok := probe["errorCount"]; ok {
					return value, nil
				}
			}
		}
		offset = start + 1
	}
	return nil, errors.New("mysqlsh の出力にチェッカーの JSON が見つからない")
}

// CollectUpgradeCheck は mysqlsh でアップグレードチェッカーを実行する。
//
// **チェッカーが問題を見つけても収集としては成功である。**mysqlsh は問題の有無で
// 終了コードを変えることがあるため、JSON が取れた限り終了コードは記録するだけにする。
// JSON が取れなかったときだけ失敗にする。
func CollectUpgradeCheck(ctx context.Context, run Runner, mysqlshBin string, t Target, password, targetVersion string) (*UpgradeCheck, error) {
	result, err := run(ctx, mysqlshBin, MySQLShellArgs(t, targetVersion), nil, password+"\n")
	if err != nil {
		return nil, err
	}
	report, err := ExtractJSON(result.Stdout)
	if err != nil {
		return nil, fmt.Errorf("%w（mysqlsh の終了コード %d）: %s",
			err, result.ExitCode, strings.TrimSpace(string(result.Stderr)))
	}
	var counts struct {
		ErrorCount   int `json:"errorCount"`
		WarningCount int `json:"warningCount"`
		NoticeCount  int `json:"noticeCount"`
	}
	if err := json.Unmarshal(report, &counts); err != nil {
		return nil, fmt.Errorf("チェッカーの JSON がオブジェクトではない: %w", err)
	}
	return &UpgradeCheck{
		Host:          t.Host,
		Port:          t.Port,
		TargetVersion: targetVersion,
		ShellExitCode: result.ExitCode,
		ErrorCount:    counts.ErrorCount,
		WarningCount:  counts.WarningCount,
		NoticeCount:   counts.NoticeCount,
		Report:        report,
	}, nil
}
