// 仕組みの生成ツール。config/ami_publish.yml と internal/definitions/ の定義から、
// AMI 公開パイプラインの仕組み（CloudFormation テンプレートと buildspec）の YAML ファイルを generated/ に生成する。
// **AWS は呼ばない。** デプロイは、生成物をレビューした後に担当者が AWS CLI で行う。
//
// 生成するファイル:
//
//	generated/codebuild/ami-publish-buildspec.yml                          （全環境で共通）
//	generated/cloudformation/<環境>/launch-template-stack.yml
//	generated/cloudformation/<環境>/ami-publish-pipeline-stack.yml
//	generated/cloudformation/<環境>/health-check-stack.yml
//
// 終了コード: 0 生成した / --check で差分なし、1 --check で差分あり、2 使い方・設定値の誤り、3 ファイル操作の失敗
//
//	実行: go run ./cmd/generate-definitions [--config config/ami_publish.yml] [--output-dir generated] [--check]
package main

import (
	"flag"
	"fmt"
	"os"

	"ami-publish/internal/definitions"
)

func main() {
	configPath := flag.String("config", "config/ami_publish.yml", "設定値ファイル")
	outputDirectory := flag.String("output-dir", "generated", "生成先ディレクトリ")
	check := flag.Bool("check", false, "書き出さず、生成結果が出力先の内容と一致するかだけを確認する")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: generate-definitions [--config FILE] [--output-dir DIR] [--check]")
		flag.PrintDefaults()
	}
	flag.Parse()

	configuration, err := definitions.LoadConfiguration(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	files, err := definitions.GenerateAll(configuration)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	if *check {
		differences, err := definitions.Differences(*outputDirectory, files)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(3)
		}
		if len(differences) > 0 {
			fmt.Fprintln(os.Stderr, "生成結果と出力先の内容が一致しない。go run ./cmd/generate-definitions で再生成する:")
			for _, difference := range differences {
				fmt.Fprintln(os.Stderr, "  - "+difference)
			}
			os.Exit(1)
		}
		fmt.Printf("生成結果と一致している（%d ファイル）\n", len(files))
		return
	}

	if err := definitions.WriteAll(*outputDirectory, files); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	for _, file := range files {
		fmt.Printf("生成: %s/%s\n", *outputDirectory, file.Path)
	}
	stale, err := definitions.StaleFiles(*outputDirectory, files)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	for _, path := range stale {
		fmt.Fprintf(os.Stderr, "警告: 生成対象にないファイルが残っている（不要なら削除する）: %s/%s\n", *outputDirectory, path)
	}
}
