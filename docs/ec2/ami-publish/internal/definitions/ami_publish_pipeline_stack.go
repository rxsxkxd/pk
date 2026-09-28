package definitions

import (
	"encoding/json"
	"fmt"
)

// BuildspecPath は、CodeBuild プロジェクトが参照する buildspec のリポジトリ内のパス。
const BuildspecPath = "generated/codebuild/ami-publish-buildspec.yml"

// AMIPublishPipelineStack は AMI 公開パイプラインのスタックの CloudFormation テンプレートを返す。
//
// 含めるもの:
//   - CodePipeline（V2、実行モード QUEUED、パイプライン変数 VERSION / VERIFIED）
//   - CodeBuild プロジェクト（同時実行数 1）と、そのサービスロール（AMI 作成・ヘルスチェック・スタック更新に必要な権限だけ）
//   - 起動テンプレートのスタックの更新に使う CloudFormation のサービスロール
//   - パイプラインのアーティファクト用 S3 バケット、ログ用の CloudWatch Logs ロググループ
//
// ソースはこのリポジトリで、push による自動起動は行わない（DetectChanges: false）。
// パイプラインは担当者が変数 VERSION を指定して起動する。
func AMIPublishPipelineStack(environment Environment) Map {
	pipeline := environment.Pipeline
	return M(
		"AWSTemplateFormatVersion", "2010-09-09",
		"Description", fmt.Sprintf("%s AMI publish pipeline (%s)", environment.ApplicationName, environment.Name),
		"Resources", M(
			"ArtifactBucket", artifactBucket(),
			"LogGroup", M(
				"Type", "AWS::Logs::LogGroup",
				"Properties", M(
					"LogGroupName", environment.LogGroupName(),
					"RetentionInDays", pipeline.LogRetentionDays,
				),
			),
			"LaunchTemplateStackServiceRole", launchTemplateStackServiceRole(environment),
			"CodeBuildServiceRole", codeBuildServiceRole(environment),
			"CodeBuildProject", codeBuildProject(environment),
			"CodePipelineServiceRole", codePipelineServiceRole(environment),
			"Pipeline", codePipeline(environment),
		),
		"Outputs", M(
			"PipelineName", M("Value", Ref("Pipeline")),
			"CodeBuildProjectName", M("Value", Ref("CodeBuildProject")),
			"LaunchTemplateStackServiceRoleArn", M("Value", GetAtt("LaunchTemplateStackServiceRole", "Arn")),
			"ArtifactBucketName", M("Value", Ref("ArtifactBucket")),
		),
	)
}

func artifactBucket() Map {
	return M(
		"Type", "AWS::S3::Bucket",
		"Properties", M(
			"BucketEncryption", M(
				"ServerSideEncryptionConfiguration", []any{
					M("ServerSideEncryptionByDefault", M("SSEAlgorithm", "AES256")),
				},
			),
			"PublicAccessBlockConfiguration", M(
				"BlockPublicAcls", true,
				"BlockPublicPolicy", true,
				"IgnorePublicAcls", true,
				"RestrictPublicBuckets", true,
			),
			"LifecycleConfiguration", M(
				"Rules", []any{M(
					"Id", "ExpirePipelineArtifacts",
					"Status", "Enabled",
					"ExpirationInDays", 30,
				)},
			),
		),
	)
}

// launchTemplateStackServiceRole は、AMI 公開ツールが起動テンプレートのスタックを変更セットで更新するときに
// CloudFormation に渡すサービスロール。CodeBuild 自身には起動テンプレートや IAM の変更権限を持たせない。
func launchTemplateStackServiceRole(environment Environment) Map {
	stackName := environment.LaunchTemplateStackName()
	return M(
		"Type", "AWS::IAM::Role",
		"Properties", M(
			"AssumeRolePolicyDocument", assumeRolePolicy("cloudformation.amazonaws.com"),
			"Policies", []any{M(
				"PolicyName", "manage-launch-template-stack",
				"PolicyDocument", M(
					"Version", "2012-10-17",
					"Statement", []any{
						M(
							"Sid", "ManageLaunchTemplate",
							"Effect", "Allow",
							"Action", []any{
								"ec2:CreateLaunchTemplate",
								"ec2:CreateLaunchTemplateVersion",
								"ec2:ModifyLaunchTemplate",
								"ec2:DeleteLaunchTemplate",
								"ec2:DeleteLaunchTemplateVersions",
								"ec2:CreateTags",
							},
							"Resource", Sub("arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:launch-template/*"),
						),
						M(
							"Sid", "ReadEc2",
							"Effect", "Allow",
							"Action", []any{
								"ec2:DescribeLaunchTemplates",
								"ec2:DescribeLaunchTemplateVersions",
								"ec2:DescribeImages",
								"ec2:DescribeSecurityGroups",
							},
							"Resource", "*",
						),
						M(
							"Sid", "ManageInstanceRole",
							"Effect", "Allow",
							"Action", []any{
								"iam:GetRole",
								"iam:CreateRole",
								"iam:DeleteRole",
								"iam:UpdateAssumeRolePolicy",
								"iam:GetRolePolicy",
								"iam:PutRolePolicy",
								"iam:DeleteRolePolicy",
								"iam:AttachRolePolicy",
								"iam:DetachRolePolicy",
								"iam:TagRole",
								"iam:UntagRole",
								"iam:PassRole",
							},
							"Resource", Sub("arn:${AWS::Partition}:iam::${AWS::AccountId}:role/"+stackName+"-*"),
						),
						M(
							"Sid", "ManageInstanceProfile",
							"Effect", "Allow",
							"Action", []any{
								"iam:GetInstanceProfile",
								"iam:CreateInstanceProfile",
								"iam:DeleteInstanceProfile",
								"iam:AddRoleToInstanceProfile",
								"iam:RemoveRoleFromInstanceProfile",
							},
							"Resource", Sub("arn:${AWS::Partition}:iam::${AWS::AccountId}:instance-profile/"+stackName+"-*"),
						),
					},
				),
			)},
		),
	)
}

// codeBuildServiceRole は AMI 公開ツール（Ruby）が CodeBuild 上で使う権限。
func codeBuildServiceRole(environment Environment) Map {
	application := environment.ApplicationName
	instanceARN := "arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:instance/" + environment.ReleaseInstanceID
	imageARN := "arn:${AWS::Partition}:ec2:${AWS::Region}::image/*"
	snapshotARN := "arn:${AWS::Partition}:ec2:${AWS::Region}::snapshot/*"
	launchTemplateStackARN := "arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/" +
		environment.LaunchTemplateStackName() + "/*"
	applicationTagCondition := M("StringEquals", M("ec2:ResourceTag/App", application))

	return M(
		"Type", "AWS::IAM::Role",
		"Properties", M(
			"AssumeRolePolicyDocument", assumeRolePolicy("codebuild.amazonaws.com"),
			"Policies", []any{M(
				"PolicyName", "publish-ami",
				"PolicyDocument", M(
					"Version", "2012-10-17",
					"Statement", []any{
						M(
							"Sid", "WriteBuildLogs",
							"Effect", "Allow",
							"Action", []any{"logs:CreateLogStream", "logs:PutLogEvents"},
							"Resource", GetAtt("LogGroup", "Arn"),
						),
						M(
							"Sid", "ReadWritePipelineArtifacts",
							"Effect", "Allow",
							"Action", []any{"s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"},
							"Resource", Sub("${ArtifactBucket.Arn}/*"),
						),
						M(
							"Sid", "CreateImage",
							"Effect", "Allow",
							"Action", "ec2:CreateImage",
							"Resource", []any{Sub(instanceARN), Sub(imageARN), Sub(snapshotARN)},
						),
						M(
							"Sid", "ReadInstanceState",
							"Effect", "Allow",
							"Action", "ec2:DescribeInstances",
							"Resource", "*",
						),
						M(
							"Sid", "StartStoppedReleaseInstance",
							"Effect", "Allow",
							"Action", "ec2:StartInstances",
							"Resource", Sub(instanceARN),
						),
						M(
							"Sid", "TagImage",
							"Effect", "Allow",
							"Action", "ec2:CreateTags",
							"Resource", []any{Sub(imageARN), Sub(snapshotARN)},
						),
						M(
							"Sid", "DescribeImagesAndSnapshots",
							"Effect", "Allow",
							"Action", []any{"ec2:DescribeImages", "ec2:DescribeSnapshots"},
							"Resource", "*",
						),
						M(
							"Sid", "DeleteFailedImage",
							"Effect", "Allow",
							"Action", []any{"ec2:DeregisterImage", "ec2:DeleteSnapshot"},
							"Resource", []any{Sub(imageARN), Sub(snapshotARN)},
							"Condition", applicationTagCondition,
						),
						M(
							"Sid", "RunHealthCheck",
							"Effect", "Allow",
							"Action", "ssm:SendCommand",
							"Resource", []any{
								Sub(instanceARN),
								Sub("arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:document/" +
									environment.HealthCheckDocumentName()),
							},
						),
						M(
							"Sid", "ReadCommandAndInstanceStatus",
							"Effect", "Allow",
							"Action", []any{"ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"},
							"Resource", "*",
						),
						M(
							"Sid", "UpdateLaunchTemplateStack",
							"Effect", "Allow",
							"Action", []any{
								"cloudformation:DescribeStacks",
								"cloudformation:CreateChangeSet",
								"cloudformation:DescribeChangeSet",
								"cloudformation:ExecuteChangeSet",
								"cloudformation:DeleteChangeSet",
							},
							"Resource", Sub(launchTemplateStackARN),
						),
						M(
							"Sid", "ReadOwnStackOutputs",
							"Effect", "Allow",
							"Action", "cloudformation:DescribeStacks",
							"Resource", Ref("AWS::StackId"),
						),
						M(
							"Sid", "PassLaunchTemplateStackServiceRole",
							"Effect", "Allow",
							"Action", "iam:PassRole",
							"Resource", GetAtt("LaunchTemplateStackServiceRole", "Arn"),
							"Condition", M("StringEquals", M("iam:PassedToService", "cloudformation.amazonaws.com")),
						),
					},
				),
			)},
		),
	)
}

func codeBuildProject(environment Environment) Map {
	return M(
		"Type", "AWS::CodeBuild::Project",
		"Properties", M(
			"Name", environment.CodeBuildProjectName(),
			"Description", "Create an AMI from the release instance and update the launch template stack",
			"ServiceRole", GetAtt("CodeBuildServiceRole", "Arn"),
			"Artifacts", M("Type", "CODEPIPELINE"),
			"Source", M(
				"Type", "CODEPIPELINE",
				"BuildSpec", BuildspecPath,
			),
			"Environment", M(
				"Type", "LINUX_CONTAINER",
				"ComputeType", "BUILD_GENERAL1_SMALL",
				"Image", codeBuildImage,
				"EnvironmentVariables", []any{
					M("Name", "AMI_PUBLISH_ENVIRONMENT", "Value", environment.Name, "Type", "PLAINTEXT"),
				},
			),
			"TimeoutInMinutes", environment.Timeouts.CodeBuildMinutes,
			"ConcurrentBuildLimit", 1,
			"LogsConfig", M(
				"CloudWatchLogs", M(
					"Status", "ENABLED",
					"GroupName", Ref("LogGroup"),
					"StreamName", "codebuild",
				),
			),
		),
	)
}

func codePipelineServiceRole(environment Environment) Map {
	return M(
		"Type", "AWS::IAM::Role",
		"Properties", M(
			"AssumeRolePolicyDocument", assumeRolePolicy("codepipeline.amazonaws.com"),
			"Policies", []any{M(
				"PolicyName", "run-ami-publish-pipeline",
				"PolicyDocument", M(
					"Version", "2012-10-17",
					"Statement", []any{
						M(
							"Sid", "ReadWritePipelineArtifacts",
							"Effect", "Allow",
							"Action", []any{"s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"},
							"Resource", Sub("${ArtifactBucket.Arn}/*"),
						),
						M(
							"Sid", "ReadArtifactBucket",
							"Effect", "Allow",
							"Action", []any{"s3:GetBucketVersioning", "s3:GetBucketLocation"},
							"Resource", GetAtt("ArtifactBucket", "Arn"),
						),
						M(
							"Sid", "UseSourceConnection",
							"Effect", "Allow",
							"Action", []any{"codeconnections:UseConnection", "codestar-connections:UseConnection"},
							"Resource", environment.Pipeline.SourceConnectionARN,
						),
						M(
							"Sid", "RunCodeBuild",
							"Effect", "Allow",
							"Action", []any{"codebuild:StartBuild", "codebuild:BatchGetBuilds"},
							"Resource", GetAtt("CodeBuildProject", "Arn"),
						),
					},
				),
			)},
		),
	)
}

// codeBuildEnvironmentVariables は、パイプライン変数と実行 ID を CodeBuild に渡す設定（JSON 文字列）。
func codeBuildEnvironmentVariables() string {
	variables := []map[string]string{
		{"name": "VERSION", "value": "#{variables.VERSION}", "type": "PLAINTEXT"},
		{"name": "VERIFIED", "value": "#{variables.VERIFIED}", "type": "PLAINTEXT"},
		{"name": "PIPELINE_EXECUTION_ID", "value": "#{codepipeline.PipelineExecutionId}", "type": "PLAINTEXT"},
	}
	encoded, err := json.Marshal(variables)
	if err != nil {
		panic(err) // 固定値なので失敗しない
	}
	return string(encoded)
}

func codePipeline(environment Environment) Map {
	pipeline := environment.Pipeline
	return M(
		"Type", "AWS::CodePipeline::Pipeline",
		"Properties", M(
			"Name", environment.PipelineName(),
			"PipelineType", "V2",
			"ExecutionMode", "QUEUED",
			"RoleArn", GetAtt("CodePipelineServiceRole", "Arn"),
			"ArtifactStore", M("Type", "S3", "Location", Ref("ArtifactBucket")),
			"Variables", []any{
				M(
					"Name", "VERSION",
					"Description", "Application release version to publish as an AMI (e.g. v1.2.3). Required.",
				),
				M(
					"Name", "VERIFIED",
					"DefaultValue", "manual",
					"Description", "How the release was verified: manual (phase 1) or automated (release verification pipeline)",
				),
			},
			"Stages", []any{
				M(
					"Name", "Source",
					"Actions", []any{M(
						"Name", "Source",
						"ActionTypeId", M(
							"Category", "Source",
							"Owner", "AWS",
							"Provider", "CodeStarSourceConnection",
							"Version", "1",
						),
						"Configuration", M(
							"ConnectionArn", pipeline.SourceConnectionARN,
							"FullRepositoryId", pipeline.SourceRepositoryID,
							"BranchName", pipeline.SourceBranchName,
							"DetectChanges", false,
							"OutputArtifactFormat", "CODE_ZIP",
						),
						"OutputArtifacts", []any{M("Name", "SourceOutput")},
					)},
				),
				M(
					"Name", "Publish",
					"Actions", []any{M(
						"Name", "PublishAmi",
						"Namespace", "Publish",
						"ActionTypeId", M(
							"Category", "Build",
							"Owner", "AWS",
							"Provider", "CodeBuild",
							"Version", "1",
						),
						"InputArtifacts", []any{M("Name", "SourceOutput")},
						"Configuration", M(
							"ProjectName", Ref("CodeBuildProject"),
							"EnvironmentVariables", codeBuildEnvironmentVariables(),
						),
					)},
				),
			},
		),
	)
}

func assumeRolePolicy(service string) Map {
	return M(
		"Version", "2012-10-17",
		"Statement", []any{M(
			"Effect", "Allow",
			"Principal", M("Service", service),
			"Action", "sts:AssumeRole",
		)},
	)
}
