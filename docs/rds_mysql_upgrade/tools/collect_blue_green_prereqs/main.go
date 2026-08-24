// Step 1（成立条件チェック）の AWS 側の収集。AWS の読み取り API だけを使い、判定に要る
// JSON を --output-dir へ書き出す。**判定はしない**（evaluate_blue_green_prereqs が行う）。
//
// 収集ロジックは internal/prereqs にある。ここは CLI の配線だけを持つ。
//
//	実行: go run ./tools/collect_blue_green_prereqs \
//	        --db-instance-id <blue-id> [--region R] [--profile P] [--output-dir DIR]
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/tools/internal/prereqs"
)

func main() {
	var options prereqs.CollectOptions
	flag.StringVar(&options.DBInstanceID, "db-instance-id", "", "対象 Blue の DB インスタンス識別子（必須）")
	flag.StringVar(&options.Client.Region, "region", "", "AWS リージョン（省略時は AWS CLI の設定）")
	flag.StringVar(&options.Client.Profile, "profile", "", "AWS CLI の named profile（省略時は AWS CLI の設定）")
	flag.StringVar(&options.TargetEngineVersion, "target-engine-version", "8.4.9", "移行先の MySQL バージョン")
	flag.StringVar(&options.OutputDir, "output-dir", "", "収集した JSON の保存先（省略時は一時ディレクトリ）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: collect_blue_green_prereqs --db-instance-id ID [options]")
		flag.PrintDefaults()
	}
	flag.Parse()
	if options.DBInstanceID == "" {
		fmt.Fprintln(os.Stderr, "--db-instance-id is required.")
		os.Exit(2)
	}
	if options.OutputDir == "" {
		dir, err := os.MkdirTemp("", "rds-bg-prereqs.")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		options.OutputDir = dir
	} else if err := os.MkdirAll(options.OutputDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := prereqs.Collect(options); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("Collected read-only AWS CLI results: %s\n", options.OutputDir)
	fmt.Printf("Evaluate: go run ./tools/evaluate_blue_green_prereqs --input-dir %s\n", options.OutputDir)
}
