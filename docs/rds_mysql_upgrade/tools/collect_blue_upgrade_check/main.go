// 成立条件チェックの MySQL 側（mysqlsh コマンド）: MySQL Shell のアップグレードチェッカー
// （util.checkForServerUpgrade）を Blue に対して実行し、結果の JSON を保存する。
//
// チェッカーは移行ガイドの 0-3 にあたる。8.4 へ上げると動かなくなる定義・設定
// （削除された機能、予約語との衝突、認証プラグインなど）を MySQL Shell が調べる。
// **MySQL Shell の機能なので、コマンドとしてしか使えない。**
//
// 収集ロジックは internal/mysqlcli にある。ここは CLI の配線だけを持つ。**判定はしない。**
// チェッカーが問題を見つけても収集としては成功（終了コード 0）で、件数と
// mysqlsh の終了コードを記録する。JSON を取れなかったときだけ失敗にする。
// 出力は --output-dir へ blue-upgrade-check.json として書く。
//
//	実行: go run ./tools/collect_blue_upgrade_check \
//	        --host <blue-endpoint> --user <user> --ssl-ca <rds-ca-bundle> --output-dir <収集先>
//
// パスワードは --password-env が指す環境変数（既定 MYSQL_PASSWORD）で渡す。**引数に取らない。**
// TLS は --ssl-mode で選ぶ（既定 VERIFY_CA。DISABLED / PREFERRED / REQUIRED / VERIFY_IDENTITY も可）。
// VERIFY_CA / VERIFY_IDENTITY は --ssl-ca が必須で、それ以外では --ssl-ca を渡せない。
// mysqlsh へは標準入力（--passwords-from-stdin）で渡す。
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
	// collect_blue_green_prereqs の --target-engine-version と同じ既定値にそろえる。
	// mysqlsh 自身のバージョンより新しい値は指定できない。
	targetVersion := flag.String("target-version", "8.4.9", "移行先の MySQL バージョン")
	mysqlshBin := flag.String("mysqlsh", "mysqlsh", "mysqlsh コマンドのパス")
	timeout := flag.Duration("timeout", 10*time.Minute, "全体のタイムアウト（チェッカーは大きな DB で時間がかかる）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: collect_blue_upgrade_check --host HOST --user USER [--ssl-mode MODE] [--ssl-ca FILE] --output-dir DIR [options]")
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
	check, err := mysqlcli.CollectUpgradeCheck(ctx, mysqlcli.ExecRunner, *mysqlshBin, target, password, *targetVersion)
	if err != nil {
		return err
	}
	check.CollectedAt = time.Now().UTC().Format(time.RFC3339)

	if err := os.MkdirAll(*outputDir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(*outputDir, mysqlcli.UpgradeCheckFileName)
	if err := common.WriteJSON(path, check); err != nil {
		return err
	}
	fmt.Printf("Collected upgrade checker result: %s (errors=%d warnings=%d notices=%d)\n",
		path, check.ErrorCount, check.WarningCount, check.NoticeCount)
	return nil
}
