// 成立条件チェックの MySQL 側（mysql コマンド）: Blue へ接続し、AWS API では見えない項目を集める。
//
// 集めるもの（読み取りだけで、設定を変更しない）:
//   - version / binlog_format の実効値（0-1-02）
//   - SHOW REPLICA STATUS（0-1-06 外部 binlog レプリカ。要 REPLICATION CLIENT 権限）
//   - ユーザースキーマの InnoDB 以外のテーブル（移行ガイドの 0-2。MyISAM の棚卸し）
//
// 収集ロジックは internal/mysqlcli にある。ここは CLI の配線だけを持つ。**判定はしない。**
// 出力は --output-dir へ blue-mysql-state.json として書く。collect_blue_green_prereqs.sh の
// 出力先と同じディレクトリを指定すると、AWS 側の収集結果と一緒に置ける。
//
//	実行: go run ./tools/collect_blue_mysql_state \
//	        --host <blue-endpoint> --user <user> --ssl-ca <rds-ca-bundle> --output-dir <収集先>
//
// パスワードは --password-env が指す環境変数（既定 MYSQL_PASSWORD）で渡す。**引数に取らない。**
// TLS は --ssl-mode で選ぶ（既定 VERIFY_CA。DISABLED / PREFERRED / REQUIRED / VERIFY_IDENTITY も可）。
// VERIFY_CA / VERIFY_IDENTITY は --ssl-ca が必須で、それ以外では --ssl-ca を渡せない。
// mysql コマンドへは MYSQL_PWD で渡す。
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"rds-mysql-upgrade/tools/internal/common"
	"rds-mysql-upgrade/tools/internal/mysqlcli"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var target mysqlcli.Target
	mysqlcli.RegisterFlags(flag.CommandLine, &target, "Blue のエンドポイント（必須）")
	passwordEnv := flag.String("password-env", "MYSQL_PASSWORD", "パスワードを載せた環境変数の名前")
	outputDir := flag.String("output-dir", "", "出力先ディレクトリ（必須）")
	mysqlBin := flag.String("mysql", "mysql", "mysql コマンドのパス")
	timeout := flag.Duration("timeout", 2*time.Minute, "全体のタイムアウト")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: collect_blue_mysql_state --host HOST --user USER [--ssl-mode MODE] [--ssl-ca FILE] --output-dir DIR [options]")
		flag.PrintDefaults()
	}
	flag.Parse()

	if err := target.Validate(); err != nil || *outputDir == "" {
		if err == nil {
			err = fmt.Errorf("--output-dir は必須である")
		}
		fmt.Fprintln(os.Stderr, err)
		flag.Usage()
		os.Exit(2)
	}
	// 証明書を検証しないモードは明示したときだけ使える。使うときは警告を残す。
	if warning := target.SecurityWarning(); warning != "" {
		fmt.Fprintln(os.Stderr, warning)
	}
	password := os.Getenv(*passwordEnv)
	if password == "" {
		return fmt.Errorf("環境変数 %s が空である。パスワードは環境変数で渡すこと（例: read -rs %s && export %s）",
			*passwordEnv, *passwordEnv, *passwordEnv)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	state, err := mysqlcli.CollectState(ctx, mysqlcli.ExecRunner, *mysqlBin, target, password)
	if err != nil {
		return err
	}
	state.CollectedAt = time.Now().UTC().Format(time.RFC3339)

	if err := os.MkdirAll(*outputDir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(*outputDir, mysqlcli.StateFileName)
	if err := common.WriteJSON(path, state); err != nil {
		return err
	}
	fmt.Printf("Collected MySQL-side state: %s\n", path)
	return nil
}
