// 移行カタログと RDS インベントリから、切替前レビュー用の Markdown レポートを生成する。
//
// 組み立ては internal/report にある。ここは CLI の配線だけを持つ。
// AWS を一切呼ばない。YAML 生成（generate_blue_green_config）とは別コマンドで、
// 設定ファイルを書き換えずレポートだけを出す。
//
//	実行: go -C scripts run ./generate_blue_green_config_report \
//	        --catalog CATALOG --inventory INVENTORY --environment ENV --output FILE
//
// go -C はカレントディレクトリを scripts/ へ移すため、パスは絶対パスで渡す。
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/tools/internal/common"
	"rds-mysql-upgrade/tools/internal/generate"
	"rds-mysql-upgrade/tools/internal/report"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	catalogPath := flag.String("catalog", "", "移行カタログ YAML（必須）")
	inventoryPath := flag.String("inventory", "", "RDS インベントリ JSON（必須）")
	environmentName := flag.String("environment", "", "対象の環境名（必須）")
	outputPath := flag.String("output", "", "生成先 Markdown（必須）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr,
			"Usage: generate_blue_green_config_report --catalog FILE --inventory FILE"+
				" --environment ENV --output FILE")
		flag.PrintDefaults()
	}
	flag.Parse()

	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "Unknown argument: %s\n", flag.Arg(0))
		flag.Usage()
		os.Exit(2)
	}
	if *catalogPath == "" || *inventoryPath == "" || *environmentName == "" || *outputPath == "" {
		flag.Usage()
		os.Exit(2)
	}

	catalog, err := generate.ReadCatalog(*catalogPath)
	if err != nil {
		return err
	}
	inventory, err := common.ReadInventory(*inventoryPath)
	if err != nil {
		return err
	}
	document, err := report.Build(catalog, inventory, *environmentName)
	if err != nil {
		return err
	}
	if err := report.Write(*outputPath, document); err != nil {
		return err
	}
	fmt.Printf("Generated Blue/Green config report: %s\n", *outputPath)
	return nil
}
