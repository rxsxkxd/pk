// Step 2 の CloudFormation テンプレートが宣言している DB パラメータ名を列挙する。
//
// Step 4 の実効値収集（collect_green_runtime_values.sh）が、
// performance_schema.global_variables へ問い合わせる対象を決めるために使う。
// **名前だけを出す。値は読まないし、組み込み関数の解決も行わない。**
//
// 読み取りは internal/cfn が担う（短縮記法 !Ref / !Sub を長形式へ正規化する）。
// この経路は VerifyGreen でのみ使うため、Go への依存は Step 4 に閉じている。
//
// 実行: go run ./scripts/list_db_parameter_names --template FILE
package main

import (
	"flag"
	"fmt"
	"os"
	"regexp"
	"sort"

	"rds-mysql-upgrade/scripts/internal/cfn"
)

// SQL へ埋め込むため、識別子として安全な名前だけを通す。
var safeName = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	template := flag.String("template", "", "Step 2 の CloudFormation テンプレート（必須）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: list_db_parameter_names --template FILE")
		flag.PrintDefaults()
	}
	flag.Parse()

	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "Unknown argument: %s\n", flag.Arg(0))
		flag.Usage()
		os.Exit(2)
	}
	if *template == "" {
		flag.Usage()
		os.Exit(2)
	}

	group, err := cfn.ReadDBParameterGroup(*template)
	if err != nil {
		return err
	}

	// 実値が決まっているものも組み込み関数のものも、名前は同じように必要である。
	names := make([]string, 0, len(group.Declared)+len(group.Unresolved))
	for name := range group.Declared {
		names = append(names, name)
	}
	for name := range group.Unresolved {
		names = append(names, name)
	}
	if len(names) == 0 {
		return fmt.Errorf("%s: パラメータが 1 つも宣言されていない", *template)
	}
	sort.Strings(names)

	for _, name := range names {
		if !safeName.MatchString(name) {
			return fmt.Errorf("%s: パラメータ名として扱えない文字が含まれる: %q", *template, name)
		}
		fmt.Println(name)
	}
	return nil
}
