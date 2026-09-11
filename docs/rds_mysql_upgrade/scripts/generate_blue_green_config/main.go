// RDS インベントリと移行カタログから Blue/Green 実行設定を生成する。
//
// 生成ロジックは internal/generate にある。ここは CLI の配線だけを持つ。
// AWS を一切呼ばない。入力は collect_rds_instance_inventory が収集した JSON と、
// 人が管理する移行カタログ（config/migration-catalog.yml）だけである。
//
//	実行: go -C scripts run ./generate_blue_green_config \
//	        --catalog CATALOG --inventory INVENTORY --environment ENV --output FILE
//
// go -C はカレントディレクトリを scripts/ へ移すため、パスは絶対パスで渡す。
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/scripts/internal/common"
	"rds-mysql-upgrade/scripts/internal/generate"
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
	environmentName := flag.String("environment", "", "生成対象の環境名（必須）")
	outputPath := flag.String("output", "", "生成先 YAML（必須）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr,
			"Usage: generate_blue_green_config --catalog FILE --inventory FILE"+
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
	document, err := generate.Generate(catalog, inventory, *environmentName)
	if err != nil {
		return err
	}
	if err := generate.Write(*outputPath, document); err != nil {
		return err
	}
	fmt.Printf("Generated Blue/Green config: %s\n", *outputPath)
	return nil
}
