package definitions

// OutputsEnvironmentFile は、AMI 公開ツールが出力値を書き出すファイル名。
const OutputsEnvironmentFile = "ami_publish_outputs.env"

// CodeBuild のビルド環境。頻繁には変えないため、設定値ファイルではなくここで固定する。
// イメージを変えるときは、そのイメージに入っている Ruby 3.4 系のバージョンに codeBuildRubyVersion を合わせる。
const (
	// codeBuildImage は CodeBuild 標準イメージ（Ubuntu 24.04。rbenv と Ruby 3.4 系が入っている）。
	codeBuildImage = "aws/codebuild/standard:8.0"
	// codeBuildRubyVersion は、codeBuildImage に入っている Ruby 3.4 系のバージョン。
	// イメージの更新でなくなると rbenv local が失敗するので、そのときはイメージにあるバージョンに上げる。
	codeBuildRubyVersion = "3.4.10"
)

// AMIPublishBuildspec は CodeBuild プロジェクト ami-publish の buildspec を返す（全環境で共通）。
//
// シェルで行うのは、Ruby の選択、Ruby の依存 gem のインストール、AMI 公開ツールの実行、出力値の受け渡しだけ。
// Ruby は runtime-versions ではなく、CodeBuild 標準イメージに入っている rbenv で、イメージにある 3.4 系を選ぶ
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
					"if command -v rbenv >/dev/null 2>&1; then rbenv local " + codeBuildRubyVersion + "; fi",
					"ruby --version",
					"echo 'Entered install phase.'",
					"aws --version",
					`bundle config set --local deployment true && bundle config set --local without "development test" && bundle install`,
				},
			),
			"build", M(
				"commands", []any{
					`bundle exec ruby bin/ami_publish run --environment "$AMI_PUBLISH_ENVIRONMENT" --version "$VERSION" --verified "$VERIFIED" --pipeline-execution-id "$PIPELINE_EXECUTION_ID" --output-env-file ` + OutputsEnvironmentFile,
					"set -a && . ./" + OutputsEnvironmentFile + " && set +a",
				},
			),
		),
	)
}
