// Step 2 の生成。収集済み JSON と移行ルールから、8.4 パラメータグループの CloudFormation
// テンプレートとレビュー用 Markdown を作る。**AWS は呼ばない。**
//
// パラメータの扱いの正本は移行ルール YAML（既定 config/mysql80-to-84-parameter-rules.yml）である。
// 生成ロジックは internal/paramgen にある。
//
// 終了コード: 0 要レビュー・生成不可なし / 1 残っている、または入力の不備 / 2 使い方の誤り
//
//	実行: go run ./tools/generate_mysql84_parameter_group \
//	        --input-dir DIR --output-dir DIR --system NAME --environment NAME [--rules FILE]
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/tools/internal/paramgen"
)

func main() {
	var options paramgen.Options
	flag.StringVar(&options.InputDir, "input-dir", "", "collect_mysql84_parameter_inputs の出力先（必須）")
	flag.StringVar(&options.OutputDir, "output-dir", "", "生成先（必須）")
	flag.StringVar(&options.System, "system", "", "システム名。リソース名に使う（必須）")
	flag.StringVar(&options.Environment, "environment", "", "環境名。リソース名に使う（必須）")
	flag.StringVar(&options.RulesPath, "rules", "config/mysql80-to-84-parameter-rules.yml", "移行ルール")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: generate_mysql84_parameter_group --input-dir DIR --output-dir DIR --system NAME --environment NAME [--rules FILE]")
		flag.PrintDefaults()
	}
	flag.Parse()
	for name, value := range map[string]string{"input-dir": options.InputDir, "output-dir": options.OutputDir,
		"system": options.System, "environment": options.Environment} {
		if value == "" {
			fmt.Fprintf(os.Stderr, "--%s is required.\n", name)
			flag.Usage()
			os.Exit(2)
		}
	}
	result, err := paramgen.Generate(options)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("Generated: %s\n", result.TemplatePath)
	fmt.Printf("Report: %s\n", result.ReportPath)
	fmt.Printf("結果: 生成済み=%d, 要レビュー=%d, 生成不可=%d\n", result.Generated, result.Review, result.Blocked)
	if result.Review > 0 || result.Blocked > 0 {
		os.Exit(1)
	}
}
