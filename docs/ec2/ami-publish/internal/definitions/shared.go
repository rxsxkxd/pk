package definitions

// CDK 版（cdk/go）から使う値。CDK 版は、設定値の読み込み・検証と命名規則（naming.go）もこのパッケージのものを使う。
// 同じ値を 2 か所で持たないよう、生成ツールの定義の非公開の値をここから公開する。

// CodeBuildImageID は、CodeBuild プロジェクトのイメージ（codeBuildImage）。
func CodeBuildImageID() string { return codeBuildImage }

// HealthCheckCommandLines は、ヘルスチェックの SSM ドキュメントがリリース用インスタンス上で実行するコマンド。
func HealthCheckCommandLines(environment Environment) []any { return healthCheckCommands(environment) }

// HealthCheckTimeoutSeconds は、ヘルスチェックの SSM ドキュメントの実行時間の上限（秒）。
func HealthCheckTimeoutSeconds() int { return healthCheckCommandTimeoutSeconds }
