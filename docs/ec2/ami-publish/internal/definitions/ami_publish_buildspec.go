package definitions

// OutputsEnvironmentFile は、AMI 公開ツールが出力値を書き出すファイル名。
const OutputsEnvironmentFile = "ami_publish_outputs.env"

// AMIPublishBuildspec は CodeBuild プロジェクト ami-publish の buildspec を返す（全環境で共通）。
//
// シェルで行うのは、Ruby の依存 gem のインストール、AMI 公開ツールの実行、出力値の受け渡しの 3 つだけ。
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
				"runtime-versions", M("ruby", "3.4"),
				"commands", []any{
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
