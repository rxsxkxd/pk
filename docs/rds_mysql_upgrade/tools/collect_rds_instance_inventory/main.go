// Blue/Green 設定生成用に、RDS DB インスタンスの事実情報を収集する。
//
// 収集ロジックは internal/collect にある。ここは CLI の配線だけを持つ。
//
//	実行: go run ./tools/collect_rds_instance_inventory \
//	        --region REGION --output FILE [--profile PROFILE]
//
// リポジトリのルートで実行する。引数の相対パスは実行時のカレントディレクトリ基準である。
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/tools/internal/collect"
	"rds-mysql-upgrade/tools/internal/common"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	region := flag.String("region", "", "収集対象の AWS リージョン（必須）")
	profile := flag.String("profile", "", "AWS CLI の named profile（省略可）")
	output := flag.String("output", "", "収集結果の出力先 JSON（必須）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr,
			"Usage: collect_rds_instance_inventory --region REGION --output FILE [--profile PROFILE]")
		flag.PrintDefaults()
	}
	flag.Parse()

	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "Unknown argument: %s\n", flag.Arg(0))
		flag.Usage()
		os.Exit(2)
	}
	if *region == "" || *output == "" {
		flag.Usage()
		os.Exit(2)
	}

	inventory, err := collect.Inventory(collect.Options{Region: *region, Profile: *profile})
	if err != nil {
		return err
	}
	if err := common.WriteInventory(*output, inventory); err != nil {
		return err
	}
	fmt.Printf("Collected RDS instance inventory: %s\n", *output)
	return nil
}
