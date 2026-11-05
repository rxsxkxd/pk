package stacks

import (
	"fmt"
	"strconv"

	"ami-publish/internal/definitions"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsssm"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// NewHealthCheckStack は、再起動後のヘルスチェックのスタック（<app>-<env>-health-check）を定義する。
//
// SSM ドキュメントには L2 の構成要素がないので、L1（CfnDocument）で書く。
// 実行するコマンドは、仕組みの生成ツールと同じもの（definitions.HealthCheckCommandLines）を使う。
func NewHealthCheckStack(scope constructs.Construct, environment definitions.Environment) awscdk.Stack {
	stack := newStack(scope, environment.HealthCheckStackName(),
		fmt.Sprintf("%s health check (SSM document) for the AMI publish pipeline (%s)",
			environment.ApplicationName, environment.Name), environment)

	document := awsssm.NewCfnDocument(stack, jsii.String("HealthCheckDocument"), &awsssm.CfnDocumentProps{
		Name:         jsii.String(environment.HealthCheckDocumentName()),
		DocumentType: jsii.String("Command"),
		UpdateMethod: jsii.String("NewVersion"),
		Content: map[string]any{
			"schemaVersion": "2.2",
			"description":   "Check that the application responds after the instance reboot",
			"mainSteps": []any{map[string]any{
				"action": "aws:runShellScript",
				"name":   "healthCheck",
				"inputs": map[string]any{
					"timeoutSeconds": strconv.Itoa(definitions.HealthCheckTimeoutSeconds()),
					"runCommand":     definitions.HealthCheckCommandLines(environment),
				},
			}},
		},
	})
	// SSM ドキュメントの名前: AMI 公開パイプラインのスタックが参照する（実行の権限の対象）
	exportOutput(stack, "HealthCheckDocumentName", document.Ref(),
		environment.HealthCheckStackExport("DocumentName"))

	// 既存のロールにアタッチするための、Basic 認証のパラメーターの読み取りの管理ポリシー（生成ツールと同じく残している）
	if name := environment.HealthCheck.BasicAuthParameterName; name != "" {
		policy := awsiam.NewManagedPolicy(stack, jsii.String("BasicAuthParameterReadPolicy"), &awsiam.ManagedPolicyProps{
			Description: jsii.String("Attach to the release instance role: read the basic auth parameter for the health check"),
			Statements: &[]awsiam.PolicyStatement{awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
				Actions:   jsii.Strings("ssm:GetParameter"),
				Resources: &[]*string{sub("arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter"+name, nil)},
			})},
		})
		output(stack, "BasicAuthParameterReadPolicyArn", policy.ManagedPolicyArn())
	}
	return stack
}
