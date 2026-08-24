// Step 2 の収集。移行元 8.0 パラメータグループと 8.0 / 8.4 の既定値を AWS の読み取り API で
// 集め、--output-dir へ書き出す。生成は generate_mysql84_parameter_group が行う。
//
// 収集ロジックは internal/paramgen にある。ここは CLI の配線だけを持つ。
//
//	実行: go run ./tools/collect_mysql84_parameter_inputs \
//	        --source-parameter-group <8.0-pg> [--db-instance-id ID] [--region R] [--profile P] [--output-dir DIR]
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/tools/internal/paramgen"
)

func main() {
	var options paramgen.CollectOptions
	flag.StringVar(&options.SourceParameterGroup, "source-parameter-group", "", "既存の MySQL 8.0 カスタムパラメータグループ（必須）")
	flag.StringVar(&options.DBInstanceID, "db-instance-id", "", "任意。指定するとそのインスタンスへの関連付けと適用状態も取る")
	flag.StringVar(&options.Client.Region, "region", "", "AWS リージョン（省略時は AWS CLI の設定）")
	flag.StringVar(&options.Client.Profile, "profile", "", "AWS CLI の named profile（省略時は AWS CLI の設定）")
	flag.StringVar(&options.OutputDir, "output-dir", "", "収集した JSON の保存先（省略時は一時ディレクトリ）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: collect_mysql84_parameter_inputs --source-parameter-group NAME [options]")
		flag.PrintDefaults()
	}
	flag.Parse()
	if options.SourceParameterGroup == "" {
		fmt.Fprintln(os.Stderr, "--source-parameter-group is required.")
		os.Exit(2)
	}
	if options.OutputDir == "" {
		dir, err := os.MkdirTemp("", "rds-mysql84-parameters.")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		options.OutputDir = dir
	} else if err := os.MkdirAll(options.OutputDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := paramgen.Collect(options); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("Collected read-only AWS CLI results: %s\n", options.OutputDir)
	fmt.Printf("Generate: go run ./tools/generate_mysql84_parameter_group --input-dir %s --output-dir <generated-dir> --system <system> --environment <environment>\n", options.OutputDir)
}
