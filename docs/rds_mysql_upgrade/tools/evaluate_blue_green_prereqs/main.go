// Step 1（成立条件チェック）の判定。collect_blue_green_prereqs が集めた JSON だけを読み、
// PASS / REVIEW / STOP を出す。**AWS は呼ばない。**
//
// 標準出力への一覧に加え、ゲート①の判断材料となる Markdown レポート（判定・観測値・取得元・
// MySQL 側の収集結果の詳細）を必ず書く。出力先は --output、省略時は入力ディレクトリの
// prereqs-evaluation-report.md。判定ロジックは internal/prereqs にある。
//
// 終了コード: 0 STOP なし / 1 STOP あり、または入力の不備 / 2 使い方の誤り
//
//	実行: go run ./tools/evaluate_blue_green_prereqs --input-dir DIR [--output FILE]
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"rds-mysql-upgrade/tools/internal/prereqs"
)

// reportFileName は --output を省略したときに入力ディレクトリへ書くレポートの名前である。
const reportFileName = "prereqs-evaluation-report.md"

func main() {
	inputDir := flag.String("input-dir", "", "collect_blue_green_prereqs の出力先（必須）")
	output := flag.String("output", "", "Markdown レポートの出力先（省略時は <input-dir>/"+reportFileName+"）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: evaluate_blue_green_prereqs --input-dir DIR [--output FILE]")
		flag.PrintDefaults()
	}
	flag.Parse()
	if *inputDir == "" {
		fmt.Fprintln(os.Stderr, "--input-dir is required.")
		os.Exit(2)
	}
	evaluation, err := prereqs.Evaluate(*inputDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Print(evaluation.Summary())
	// 詳細（MySQL 側の収集結果など）はレポートにしか載らないので、指定が無くても必ず書く。
	path := *output
	if path == "" {
		path = filepath.Join(*inputDir, reportFileName)
	}
	if err := os.WriteFile(path, []byte(evaluation.Report()), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("Report: %s\n", path)
	if evaluation.Count("STOP") > 0 {
		os.Exit(1)
	}
}
