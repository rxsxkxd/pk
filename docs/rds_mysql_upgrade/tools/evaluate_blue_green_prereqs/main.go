// Step 1（成立条件チェック）の判定。collect_blue_green_prereqs が集めた JSON だけを読み、
// PASS / REVIEW / STOP を出す。**AWS は呼ばない。**
//
// 標準出力への一覧に加え、--output でゲート①の判断材料となる Markdown レポート
// （判定・観測値・取得元）を書く。判定ロジックは internal/prereqs にある。
//
// 終了コード: 0 STOP なし / 1 STOP あり、または入力の不備 / 2 使い方の誤り
//
//	実行: go run ./tools/evaluate_blue_green_prereqs --input-dir DIR [--output FILE]
package main

import (
	"flag"
	"fmt"
	"os"

	"rds-mysql-upgrade/tools/internal/prereqs"
)

func main() {
	inputDir := flag.String("input-dir", "", "collect_blue_green_prereqs の出力先（必須）")
	output := flag.String("output", "", "Markdown レポートの出力先（省略時は標準出力の一覧だけ）")
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
	if *output != "" {
		if err := os.WriteFile(*output, []byte(evaluation.Report()), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Printf("Report: %s\n", *output)
	}
	if evaluation.Count("STOP") > 0 {
		os.Exit(1)
	}
}
