// Step 7（後始末）: 承認済みの Blue/Green Deployment と旧 Blue（<source>-old1）を削除する。
//
// **パイプラインからは外し、人が実行するツールにしている。**旧 Blue の削除は不可逆で、
// 切り戻し不要の判断や逆方向レプリケーションの確認と一体で行うべき作業のためである。
// **実行には破壊的な権限が要る**（rds:DeleteBlueGreenDeployment / DeleteDBInstance /
// CreateDBSnapshot ほか）。パイプラインの実行ロールは持たないので、作業者が引き受けて実行する。
//
// 手順と安全弁は internal/cleanup にある。ここは CLI の配線だけを持つ。
//
//	実行: go run ./tools/cleanup --config config/blue-green/staging.deployment.yml --service example-service
//
// 逆方向レプリケーションの確認（任意）は --mysql-user を指定したときだけ行う。
// TLS は --ssl-mode で選ぶ（既定 VERIFY_CA で --ssl-ca が必須。DISABLED / PREFERRED /
// REQUIRED / VERIFY_IDENTITY も可）。パスワードは --mysql-password-env の環境変数で渡し、
// 空なら端末から対話入力する（エコーしない）。
//
// 終了コード: 0 望ましい終了状態に到達 / 1 到達しておらず自動では到達できない / 2 使い方の誤り
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/tools/internal/cleanup"
	"rds-mysql-upgrade/tools/internal/mysqlcli"
)

func main() {
	var options cleanup.Options
	flag.StringVar(&options.ConfigPath, "config", "", "環境別設定ファイル（必須）")
	flag.StringVar(&options.Service, "service", "", "config の services 配下に定義したサービス名（必須）")
	flag.StringVar(&options.Region, "region", "", "AWS リージョン（設定ファイルの aws_region を上書き）")
	flag.StringVar(&options.Profile, "profile", "", "AWS CLI の named profile（省略時は AWS CLI の既定認証情報）")
	flag.StringVar(&options.OutputDir, "output-dir", "", "応答 JSON の保存先（省略時は一時ディレクトリ）")
	flag.StringVar(&options.MySQL.User, "mysql-user", "", "逆方向レプリケーション確認のための旧 Blue への接続ユーザー（任意）")
	flag.IntVar(&options.MySQL.Port, "mysql-port", 3306, "旧 Blue の接続ポート")
	flag.StringVar(&options.MySQL.SSLMode, "ssl-mode", mysqlcli.DefaultSSLMode,
		"TLS の扱い: DISABLED / PREFERRED / REQUIRED / VERIFY_CA / VERIFY_IDENTITY（VERIFY_* は --ssl-ca が必須）")
	flag.StringVar(&options.MySQL.SSLCA, "ssl-ca", "", "RDS の CA バンドル（VERIFY_CA / VERIFY_IDENTITY のときだけ指定する）")
	passwordEnv := flag.String("mysql-password-env", "MYSQL_PASSWORD", "パスワードを載せた環境変数の名前")
	flag.StringVar(&options.MySQLBin, "mysql", "mysql", "mysql コマンドのパス")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: cleanup --config FILE --service NAME [options]")
		flag.PrintDefaults()
	}
	flag.Parse()
	if options.ConfigPath == "" || options.Service == "" {
		flag.Usage()
		os.Exit(2)
	}
	if options.OutputDir == "" {
		dir, err := os.MkdirTemp("", "rds-bg-cleanup.")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		options.OutputDir = dir
	} else if err := os.MkdirAll(options.OutputDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	options.MySQLPassword = os.Getenv(*passwordEnv)
	options.ReadPassword = cleanup.ReadPasswordFromTerminal
	os.Exit(cleanup.Run(options, os.Stdout, os.Stderr))
}
