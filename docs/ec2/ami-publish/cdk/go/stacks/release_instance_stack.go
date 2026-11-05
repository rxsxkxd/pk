package stacks

import (
	"fmt"

	"ami-publish/internal/definitions"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// NewReleaseInstanceStack は、リリース用インスタンスの IAM ロールのスタック（<app>-<env>-release-instance）を定義する。
//
// リリース用インスタンスに、ヘルスチェックの区間だけ紐付けるロールとインスタンスプロファイル。
// 許可は A（AmazonSSMManagedInstanceCore）、B（ヘルスチェックの出力を CloudWatch Logs に送る）、
// C（Basic 認証のパラメーターの読み取り。設定したときだけ）。紐付けは AMI 公開ツールが行う。
func NewReleaseInstanceStack(scope constructs.Construct, environment definitions.Environment) awscdk.Stack {
	stack := newStack(scope, environment.ReleaseInstanceStackName(),
		fmt.Sprintf("%s release instance IAM role for the AMI publish pipeline (%s)",
			environment.ApplicationName, environment.Name), environment)

	statements := []awsiam.PolicyStatement{
		awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
			Sid:     jsii.String("WriteHealthCheckOutput"),
			Actions: jsii.Strings("logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"),
			Resources: &[]*string{sub("arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:"+
				environment.LogGroupName()+":*", nil)},
		}),
		awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
			Sid:       jsii.String("FindLogGroup"),
			Actions:   jsii.Strings("logs:DescribeLogGroups"),
			Resources: jsii.Strings("*"),
		}),
	}
	if name := environment.HealthCheck.BasicAuthParameterName; name != "" {
		statements = append(statements, awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
			Sid:       jsii.String("ReadBasicAuthParameter"),
			Actions:   jsii.Strings("ssm:GetParameter"),
			Resources: &[]*string{sub("arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter"+name, nil)},
		}))
	}

	role := awsiam.NewRole(stack, jsii.String("ReleaseInstanceRole"), &awsiam.RoleProps{
		Description: jsii.String("Role of the release instance (the source of the AMI): SSM and the health check"),
		AssumedBy:   awsiam.NewServicePrincipal(jsii.String("ec2.amazonaws.com"), nil),
		ManagedPolicies: &[]awsiam.IManagedPolicy{
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonSSMManagedInstanceCore")),
		},
		InlinePolicies: &map[string]awsiam.PolicyDocument{
			"health-check": awsiam.NewPolicyDocument(&awsiam.PolicyDocumentProps{Statements: &statements}),
		},
	})
	awscdk.Tags_Of(role).Add(jsii.String("App"), jsii.String(environment.ApplicationName), nil)
	profile := awsiam.NewInstanceProfile(stack, jsii.String("ReleaseInstanceProfile"), &awsiam.InstanceProfileProps{
		Role: role,
	})

	// AMI 公開パイプラインのスタックが参照する（AMI 公開ツールがヘルスチェックの区間だけ紐付ける）
	exportOutput(stack, "InstanceProfileArn", profile.InstanceProfileArn(),
		environment.ReleaseInstanceStackExport("InstanceProfileArn"))
	exportOutput(stack, "RoleArn", role.RoleArn(), environment.ReleaseInstanceStackExport("RoleArn"))
	output(stack, "InstanceProfileName", profile.InstanceProfileName())
	output(stack, "RoleName", role.RoleName())
	return stack
}
