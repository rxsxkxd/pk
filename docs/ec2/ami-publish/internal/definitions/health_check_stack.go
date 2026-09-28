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
func HealthCheckStack(environmentName string, environment Environment) Map {
	settings := environment.HealthCheck
	return M(
		"AWSTemplateFormatVersion", "2010-09-09",
		"Description", fmt.Sprintf("%s health check (SSM document) for the AMI publish pipeline (%s)",
			environment.ApplicationName, environmentName),
		"Resources", M(
			"HealthCheckDocument", M(
				"Type", "AWS::SSM::Document",
				"Properties", M(
					"Name", settings.SSMDocumentName,
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
								"runCommand", []any{
									"set -u",
									"for attempt in $(seq 1 30); do",
									fmt.Sprintf("  if curl -fsS -o /dev/null %s; then echo 'health check passed'; exit 0; fi", settings.URL),
									"  sleep 5",
									"done",
									fmt.Sprintf("echo 'health check failed: %s did not respond'", settings.URL),
									"exit 1",
								},
							),
						)},
					),
				),
			),
		),
		"Outputs", M(
			"HealthCheckDocumentName", M("Value", Ref("HealthCheckDocument")),
		),
	)
}
