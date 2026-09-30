package definitions

import (
	"fmt"
	"strconv"
)

// ヘルスチェックの SSM ドキュメントの実行時間の上限（秒）。
// AMI 公開ツール側の待機時間（timeouts.health_check_seconds）はこれより長くする。
const healthCheckCommandTimeoutSeconds = 240

// HealthCheckStack は、再起動後のヘルスチェックのスタックの CloudFormation テンプレートを返す。
//
// ヘルスチェックの SSM ドキュメントは、AMI 作成時の再起動の後に、アプリが自動で起動して
// 応答するかをリリース用インスタンス上で確認する。AMI 公開ツールはこのドキュメントだけを実行し、
// 任意のコマンドを送る AWS-RunShellScript は使わない。
//
// health_check.basic_auth_parameter_name を指定した場合は、Basic 認証を付けてアクセスする。
// 認証情報（「ユーザー名:パスワード」）は SSM Parameter Store の SecureString に置き、実行時に
// インスタンスのロールで取り出す。ドキュメントの中身・パラメーター・ログには認証情報を出さず、
// curl にもコマンドライン引数ではなく標準入力（-K -）で渡す。
// 取り出す権限は IAM の管理ポリシーとしてこのスタックに作り、リリース用インスタンスのロールに担当者がアタッチする。
func HealthCheckStack(environment Environment) Map {
	settings := environment.HealthCheck
	resources := M(
		"HealthCheckDocument", M(
			"Type", "AWS::SSM::Document",
			"Properties", M(
				"Name", environment.HealthCheckDocumentName(),
				"DocumentType", "Command",
				"UpdateMethod", "NewVersion",
				"Content", M(
					"schemaVersion", "2.2",
					"description", "Check that the application responds after the instance reboot",
					"mainSteps", []any{M(
						"action", "aws:runShellScript",
						"name", "healthCheck",
						"inputs", M(
							"timeoutSeconds", strconv.Itoa(healthCheckCommandTimeoutSeconds),
							"runCommand", healthCheckCommands(environment),
						),
					)},
				),
			),
		),
	)
	outputs := M(
		// SSM ドキュメントの名前: AMI 公開パイプラインのスタックが参照する（実行の権限の対象）
		"HealthCheckDocumentName", M(
			"Value", Ref("HealthCheckDocument"),
			"Export", M("Name", environment.HealthCheckStackExport("DocumentName")),
		),
	)

	if settings.BasicAuthParameterName != "" {
		resources = append(resources, Entry{Key: "BasicAuthParameterReadPolicy", Value: M(
			"Type", "AWS::IAM::ManagedPolicy",
			"Properties", M(
				"Description", "Attach to the release instance role: read the basic auth parameter for the health check",
				"PolicyDocument", M(
					"Version", "2012-10-17",
					"Statement", []any{M(
						"Effect", "Allow",
						"Action", "ssm:GetParameter",
						"Resource", Sub("arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter"+
							settings.BasicAuthParameterName),
					)},
				),
			),
		)})
		outputs = append(outputs, Entry{Key: "BasicAuthParameterReadPolicyArn", Value: M(
			"Description", "Attach this managed policy to the IAM role of the release instance",
			"Value", Ref("BasicAuthParameterReadPolicy"),
		)})
	}

	return M(
		"AWSTemplateFormatVersion", "2010-09-09",
		"Description", fmt.Sprintf("%s health check (SSM document) for the AMI publish pipeline (%s)",
			environment.ApplicationName, environment.Name),
		"Resources", resources,
		"Outputs", outputs,
	)
}

// healthCheckCommands は、SSM ドキュメントがリリース用インスタンス上で実行するシェルのコマンド。
// 5 秒間隔で最大 30 回アクセスし、2xx が返れば成功。失敗時は最後の HTTP ステータスを出す（認証情報は出さない）。
func healthCheckCommands(environment Environment) []any {
	settings := environment.HealthCheck
	commands := []any{"set -u"}
	curlOptions := "-sS -o /dev/null -w '%{http_code}'"
	curlPrefix := ""
	if settings.BasicAuthParameterName != "" {
		name := settings.BasicAuthParameterName
		commands = append(commands,
			"if ! command -v aws >/dev/null 2>&1; then echo 'health check failed: AWS CLI is not installed (needed to read the basic auth parameter)'; exit 1; fi",
			fmt.Sprintf("if ! credentials=$(aws ssm get-parameter --region %s --name '%s' --with-decryption --query Parameter.Value --output text); then "+
				"echo 'health check failed: cannot read the basic auth parameter %s (check the release instance role)'; exit 1; fi",
				environment.AWSRegion, name, name),
			// curl の設定ファイル形式（user = "..."）で標準入力から渡す。" と \ はエスケープする
			`escaped=$(printf '%s' "$credentials" | sed 's/[\\"]/\\&/g')`,
			`basic_auth() { printf 'user = "%s"\n' "$escaped"; }`,
		)
		curlPrefix = "basic_auth | "
		curlOptions = "-K - " + curlOptions
	}
	commands = append(commands,
		"status=none",
		"for _ in $(seq 1 30); do",
		fmt.Sprintf("  status=$(%scurl %s %s || true)", curlPrefix, curlOptions, settings.URL),
		`  case "$status" in 2??) echo 'health check passed'; exit 0 ;; esac`,
		"  sleep 5",
		"done",
		fmt.Sprintf(`echo "health check failed: %s did not respond with 2xx (last HTTP status: $status)"`, settings.URL),
		`if [ "$status" = 401 ]; then echo 'HTTP 401: the basic auth credentials were rejected or not sent'; fi`,
		"exit 1",
	)
	return commands
}
