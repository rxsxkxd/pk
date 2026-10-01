package definitions

import "fmt"

// ReleaseInstanceStack は、リリース用インスタンスの IAM ロールのスタックの CloudFormation テンプレートを返す。
//
// リリース用インスタンス（AMI の作成元）に付ける IAM ロールとインスタンスプロファイルを作る。
// 許可は docs/ec2/ami-publish-release-instance-iam.md の A〜C:
//
//	A. SSM の管理対象（AWS 管理ポリシー AmazonSSMManagedInstanceCore）
//	B. ヘルスチェックの出力を CloudWatch Logs に送る（ロググループは命名規則から決まる）
//	C. Basic 認証のパラメーターの読み取り（health_check.basic_auth_parameter_name を設定した場合だけ）
//
// このスタックは、パイプラインの仕組みではなくリリース用インスタンス側の設定のため、デプロイ用シェルスクリプト
// （up / down）には含めない。フェーズ 3（リリース検証）でインスタンスの更新の仕組みに移す可能性がある。
// インスタンスプロファイルとリリース用インスタンスの紐付けは、このスタックでは行わない。AMI 公開ツールが、
// ヘルスチェックのための区間（AMI の作成の直前からヘルスチェックの完了まで）だけ紐付け、終わったら解除する
// （docs/ec2/ami-publish-health-check-role-association-flow.md）。
// ロールとインスタンスプロファイルの ARN は Export し、AMI 公開パイプラインのスタックが参照する
// （CodeBuild のロールの iam:PassRole・許可の判定の対象と、AMI 公開ツールが使う値）。
// そのため、このスタックは AMI 公開パイプラインのスタックより先にデプロイしておく。
func ReleaseInstanceStack(environment Environment) Map {
	statements := []any{
		M(
			"Sid", "WriteHealthCheckOutput",
			"Effect", "Allow",
			"Action", []any{"logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"},
			"Resource", Sub("arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:"+
				environment.LogGroupName()+":*"),
		),
		M(
			"Sid", "FindLogGroup",
			"Effect", "Allow",
			"Action", "logs:DescribeLogGroups",
			"Resource", "*",
		),
	}
	if name := environment.HealthCheck.BasicAuthParameterName; name != "" {
		statements = append(statements, M(
			"Sid", "ReadBasicAuthParameter",
			"Effect", "Allow",
			"Action", "ssm:GetParameter",
			"Resource", Sub("arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter"+name),
		))
	}

	return M(
		"AWSTemplateFormatVersion", "2010-09-09",
		"Description", fmt.Sprintf("%s release instance IAM role for the AMI publish pipeline (%s)",
			environment.ApplicationName, environment.Name),
		"Resources", M(
			"ReleaseInstanceRole", M(
				"Type", "AWS::IAM::Role",
				"Properties", M(
					"Description", "Role of the release instance (the source of the AMI): SSM and the health check",
					"AssumeRolePolicyDocument", M(
						"Version", "2012-10-17",
						"Statement", []any{M(
							"Effect", "Allow",
							"Principal", M("Service", "ec2.amazonaws.com"),
							"Action", "sts:AssumeRole",
						)},
					),
					"ManagedPolicyArns", []any{
						Sub("arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"),
					},
					"Policies", []any{M(
						"PolicyName", "health-check",
						"PolicyDocument", M(
							"Version", "2012-10-17",
							"Statement", statements,
						),
					)},
					"Tags", []any{M("Key", "App", "Value", environment.ApplicationName)},
				),
			),
			"ReleaseInstanceProfile", M(
				"Type", "AWS::IAM::InstanceProfile",
				"Properties", M("Roles", []any{Ref("ReleaseInstanceRole")}),
			),
		),
		"Outputs", M(
			// AMI 公開パイプラインのスタックが参照する（AMI 公開ツールがヘルスチェックの区間だけ紐付ける）
			"InstanceProfileArn", M(
				"Value", GetAtt("ReleaseInstanceProfile", "Arn"),
				"Export", M("Name", environment.ReleaseInstanceStackExport("InstanceProfileArn")),
			),
			"RoleArn", M(
				"Value", GetAtt("ReleaseInstanceRole", "Arn"),
				"Export", M("Name", environment.ReleaseInstanceStackExport("RoleArn")),
			),
			"InstanceProfileName", M("Value", Ref("ReleaseInstanceProfile")),
			"RoleName", M("Value", Ref("ReleaseInstanceRole")),
		),
	)
}
