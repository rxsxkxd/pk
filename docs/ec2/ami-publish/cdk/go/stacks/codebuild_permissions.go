package stacks

import (
	"ami-publish/internal/definitions"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/jsii-runtime-go"
)

// codeBuildPolicyStatements は、AMI 公開ツール（Ruby）が CodeBuild 上で使う権限。
//
// 仕組みの生成ツールの CodeBuild のロール（internal/definitions の codeBuildServiceRole）と同じ内容。
// ただし、ビルドのログ（WriteBuildLogs）とアーティファクトの読み書き（ReadWritePipelineArtifacts）は、
// L2 の CodeBuild プロジェクトとパイプラインが自動で付けるので、ここには書かない。
// 他のスタックのリソースは、命名規則どおりの名前の Export で参照する。
// iam:PassRole は PassReleaseInstanceRole の 1 か所だけ（リリース用インスタンスのロールを EC2 に渡す場合だけ）。
func codeBuildPolicyStatements(stack awscdk.Stack, environment definitions.Environment) []awsiam.PolicyStatement {
	instanceARN := sub("arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:instance/"+environment.ReleaseInstanceID, nil)
	imageARN := sub("arn:${AWS::Partition}:ec2:${AWS::Region}::image/*", nil)
	snapshotARN := sub("arn:${AWS::Partition}:ec2:${AWS::Region}::snapshot/*", nil)
	launchTemplateStackName := importValue(environment.LaunchTemplateStackExport("StackName"))
	releaseInstanceRoleARN := importValue(environment.ReleaseInstanceStackExport("RoleArn"))

	statement := func(sid string, actions []string, resources []*string, conditions map[string]any) awsiam.PolicyStatement {
		props := &awsiam.PolicyStatementProps{
			Sid:       jsii.String(sid),
			Actions:   jsii.Strings(actions...),
			Resources: &resources,
		}
		if conditions != nil {
			props.Conditions = &conditions
		}
		return awsiam.NewPolicyStatement(props)
	}
	anyResource := []*string{jsii.String("*")}

	return []awsiam.PolicyStatement{
		statement("CreateImage", []string{"ec2:CreateImage"}, []*string{instanceARN, imageARN, snapshotARN}, nil),
		statement("ReadInstanceState", []string{"ec2:DescribeInstances"}, anyResource, nil),
		// リリース用インスタンスのロールの許可の判定（ステップ 0b。対象はそのロールだけ）
		statement("CheckReleaseInstanceRolePermissions", []string{"iam:SimulatePrincipalPolicy"},
			[]*string{releaseInstanceRoleARN}, nil),
		// ヘルスチェックの区間だけ、リリース用インスタンスにインスタンスプロファイルを紐付ける
		statement("AttachReleaseInstanceProfile",
			[]string{"ec2:AssociateIamInstanceProfile", "ec2:DisassociateIamInstanceProfile"}, []*string{instanceARN}, nil),
		statement("ReadInstanceProfileAssociations", []string{"ec2:DescribeIamInstanceProfileAssociations"}, anyResource, nil),
		statement("PassReleaseInstanceRole", []string{"iam:PassRole"}, []*string{releaseInstanceRoleARN},
			map[string]any{"StringEquals": map[string]any{"iam:PassedToService": "ec2.amazonaws.com"}}),
		statement("FindBasicAuthParameterKey", []string{"ssm:DescribeParameters"}, anyResource, nil),
		statement("StartStoppedReleaseInstance", []string{"ec2:StartInstances"}, []*string{instanceARN}, nil),
		statement("TagImage", []string{"ec2:CreateTags"}, []*string{imageARN, snapshotARN}, nil),
		statement("DescribeImagesAndSnapshots", []string{"ec2:DescribeImages", "ec2:DescribeSnapshots"}, anyResource, nil),
		statement("DeleteFailedImage", []string{"ec2:DeregisterImage", "ec2:DeleteSnapshot"}, []*string{imageARN, snapshotARN},
			map[string]any{"StringEquals": map[string]any{"ec2:ResourceTag/App": environment.ApplicationName}}),
		statement("RunHealthCheck", []string{"ssm:SendCommand"}, []*string{
			instanceARN,
			sub("arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:document/${DocumentName}",
				map[string]*string{"DocumentName": importValue(environment.HealthCheckStackExport("DocumentName"))}),
		}, nil),
		statement("ReadCommandAndInstanceStatus",
			[]string{"ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"}, anyResource, nil),
		statement("UpdateLaunchTemplateStack", []string{
			"cloudformation:DescribeStacks", "cloudformation:CreateChangeSet", "cloudformation:DescribeChangeSet",
			"cloudformation:ExecuteChangeSet", "cloudformation:DeleteChangeSet",
		}, []*string{sub("arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/${LaunchTemplateStackName}/*",
			map[string]*string{"LaunchTemplateStackName": launchTemplateStackName})}, nil),
		// CloudFormation のサービスロールを使わず、CodeBuild の権限で変更セットを実行する
		statement("UpdateLaunchTemplate", []string{"ec2:CreateLaunchTemplateVersion", "ec2:ModifyLaunchTemplate"},
			[]*string{sub("arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:launch-template/${LaunchTemplateId}",
				map[string]*string{"LaunchTemplateId": importValue(environment.LaunchTemplateStackExport("LaunchTemplateId"))})}, nil),
		// 起動テンプレートが指すインスタンスプロファイルの確認（名前は「<スタック名>-<論理 ID>-<ランダム>」）
		statement("ReadLaunchTemplateInstanceProfile", []string{"iam:GetInstanceProfile"},
			[]*string{sub("arn:${AWS::Partition}:iam::${AWS::AccountId}:instance-profile/${LaunchTemplateStackName}-*",
				map[string]*string{"LaunchTemplateStackName": launchTemplateStackName})}, nil),
		statement("ReadLaunchTemplates",
			[]string{"ec2:DescribeLaunchTemplates", "ec2:DescribeLaunchTemplateVersions"}, anyResource, nil),
		statement("ReadOwnStackOutputs", []string{"cloudformation:DescribeStacks"}, []*string{stack.StackId()}, nil),
	}
}
