package definitions

import "strings"

// OutputsEnvironmentFile は、AMI 公開ツールが出力値を書き出すファイル名。
const OutputsEnvironmentFile = "ami_publish_outputs.env"

// CodeBuild のビルド環境。頻繁には変えないため、設定値ファイルではなくここで固定する。
// イメージを変えるときは、そのイメージに codeBuildRubySeries の Ruby が入っていることを確かめる。
const (
	// codeBuildImage は CodeBuild 標準イメージ（Ubuntu 24.04。rbenv と Ruby 3.4 系が入っている）。
	codeBuildImage = "aws/codebuild/standard:8.0"
	// codeBuildRubySeries は、CodeBuild で使う Ruby の系列。パッチバージョンは書かず、
	// buildspec がイメージにあるこの系列の最新を選ぶ（イメージの更新に合わせて自動で上がる）。
	codeBuildRubySeries = "3.4"
)

// selectRubyCommand は、イメージの rbenv にある codeBuildRubySeries の最新を rbenv local で選ぶコマンド。
// プレビュー版（3.4.0-preview1 など）は選ばない。系列が 1 つもなければ失敗させる。
// rbenv のないイメージ（buildspec を Docker で再現するときの ruby:3.4 など）では何もしない。
func selectRubyCommand() string {
	pattern := "^" + strings.ReplaceAll(codeBuildRubySeries, ".", `\.`) + `\.[0-9]+$`
	return `if command -v rbenv >/dev/null 2>&1; then ` +
		`v="$(rbenv versions --bare | grep -E '` + pattern + `' | sort -V | tail -n 1)"; ` +
		`if [ -z "$v" ]; then echo 'rbenv に Ruby ` + codeBuildRubySeries + ` 系がない' >&2; false; else rbenv local "$v"; fi; fi`
}

// AMIPublishBuildspec は CodeBuild プロジェクト ami-publish の buildspec を返す（全環境で共通）。
//
// シェルで行うのは、Ruby の選択、Ruby の依存 gem のインストール、AMI 公開ツールの実行、出力値の受け渡しだけ。
// Ruby は runtime-versions ではなく、CodeBuild 標準イメージに入っている rbenv で、イメージにある 3.4 系の最新を選ぶ
// （Ruby のビルドを避けるため）。手元の .ruby-version（3.4 系の最新）とはパッチバージョンが異なってよい。
// CodePipeline のアーティファクトでは実行ビットが落ちるため、ツールは ruby コマンド経由で呼ぶ。
// Ruby のプロセスからはこのシェルの環境変数を設定できないため、出力値はファイル経由で受け取る。
func AMIPublishBuildspec() Map {
	return M(
		"version", 0.2,
		"env", M(
			"exported-variables", []any{"AMI_ID", "LAUNCH_TEMPLATE_VERSION"},
		),
		"phases", M(
			"install", M(
				"commands", []any{
					selectRubyCommand(),
					"ruby --version",
					"echo 'Entered install phase.'",
					"aws --version",
					`bundle config set --local deployment true && bundle config set --local without "development test" && bundle install`,
				},
			),
			"build", M(
				"commands", []any{
					`bundle exec ruby bin/ami_publish run --config "$` + ConfigFileEnvironmentVariable + `" --environment "$AMI_PUBLISH_ENVIRONMENT" --version "$VERSION" --verified "$VERIFIED" --health-check "$HEALTH_CHECK" --pipeline-execution-id "$PIPELINE_EXECUTION_ID" --output-env-file ` + OutputsEnvironmentFile,
					"set -a && . ./" + OutputsEnvironmentFile + " && set +a",
				},
			),
		),
	)
}
