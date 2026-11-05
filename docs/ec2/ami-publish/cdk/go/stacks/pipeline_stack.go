package stacks

import (
	"fmt"
	"strings"

	"ami-publish/internal/definitions"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awscodebuild"
	"github.com/aws/aws-cdk-go/awscdk/v2/awscodecommit"
	"github.com/aws/aws-cdk-go/awscdk/v2/awscodepipeline"
	"github.com/aws/aws-cdk-go/awscdk/v2/awscodepipelineactions"
	"github.com/aws/aws-cdk-go/awscdk/v2/awslogs"
	"github.com/aws/aws-cdk-go/awscdk/v2/awss3"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// NewPipelineStack は、AMI 公開パイプラインのスタック（<app>-<env>-ami-publish-pipeline）を定義する。
//
// CodePipeline（V2、実行モード QUEUED、変数 VERSION / HEALTH_CHECK / VERIFIED）と CodeBuild プロジェクト、
// アーティファクト用の S3 バケット、ログ用のロググループ。CodeBuild の権限は codebuild_permissions.go。
// L2 の CodePipeline・CodeBuild は、ロールとその基本の権限（S3・ログ・アクションのロール）を自動で作る。
func NewPipelineStack(scope constructs.Construct, environment definitions.Environment) awscdk.Stack {
	pipelineSettings := environment.Pipeline
	stack := newStack(scope, environment.PipelineStackName(),
		fmt.Sprintf("%s AMI publish pipeline (%s)", environment.ApplicationName, environment.Name), environment)

	// AMI 公開ツールが CodeBuild で読む設定値ファイル。デプロイ時に --parameter-overrides ConfigFile=... で変えられる
	configFile := awscdk.NewCfnParameter(stack, jsii.String("ConfigFile"), &awscdk.CfnParameterProps{
		Type:           jsii.String("String"),
		Default:        jsii.String(definitions.DefaultConfigPath),
		AllowedPattern: jsii.String(`^[A-Za-z0-9_][A-Za-z0-9._/-]*\.ya?ml$`),
		Description:    jsii.String("Configuration file read by the AMI publish tool on CodeBuild (relative to the repository root)."),
	})

	// 生成ツールの出力と同じく、スタックの削除でバケットとロググループも消す（L2 の既定は残す）。
	// バケットの中身の自動削除（autoDeleteObjects）は Lambda を使うので使わない。削除前に中身を空にする
	artifactBucket := awss3.NewBucket(stack, jsii.String("ArtifactBucket"), &awss3.BucketProps{
		Encryption:        awss3.BucketEncryption_S3_MANAGED,
		BlockPublicAccess: awss3.BlockPublicAccess_BLOCK_ALL(),
		LifecycleRules: &[]*awss3.LifecycleRule{{
			Id:         jsii.String("ExpirePipelineArtifacts"),
			Expiration: awscdk.Duration_Days(jsii.Number(30)),
		}},
		RemovalPolicy: awscdk.RemovalPolicy_DESTROY,
	})
	logGroup := awslogs.NewLogGroup(stack, jsii.String("LogGroup"), &awslogs.LogGroupProps{
		LogGroupName:  jsii.String(environment.LogGroupName()),
		RemovalPolicy: awscdk.RemovalPolicy_DESTROY,
	})
	// 保存期間は日数の設定値をそのまま使う（L2 の retention は決まった日数の列挙なので、L1 のプロパティで指定する）
	logGroup.Node().DefaultChild().(awslogs.CfnLogGroup).SetRetentionInDays(jsii.Number(pipelineSettings.LogRetentionDays))

	project := awscodebuild.NewPipelineProject(stack, jsii.String("CodeBuildProject"), &awscodebuild.PipelineProjectProps{
		ProjectName: jsii.String(environment.CodeBuildProjectName()),
		Description: jsii.String("Create an AMI from the release instance and update the launch template stack"),
		// buildspec は仕組みの生成ツールが出力したファイルをそのまま使う
		BuildSpec: awscodebuild.BuildSpec_FromSourceFilename(jsii.String(definitions.BuildspecPath)),
		Environment: &awscodebuild.BuildEnvironment{
			BuildImage:  awscodebuild.LinuxBuildImage_FromCodeBuildImageId(jsii.String(definitions.CodeBuildImageID())),
			ComputeType: awscodebuild.ComputeType_SMALL,
			EnvironmentVariables: &map[string]*awscodebuild.BuildEnvironmentVariable{
				"AMI_PUBLISH_ENVIRONMENT":                 {Value: jsii.String(environment.Name)},
				definitions.ConfigFileEnvironmentVariable: {Value: configFile.ValueAsString()},
			},
		},
		Timeout:              awscdk.Duration_Minutes(jsii.Number(environment.Timeouts.CodeBuildMinutes)),
		ConcurrentBuildLimit: jsii.Number(1),
		Logging: &awscodebuild.LoggingOptions{
			CloudWatch: &awscodebuild.CloudWatchLoggingOptions{LogGroup: logGroup, Prefix: jsii.String("codebuild")},
		},
	})
	for _, statement := range codeBuildPolicyStatements(stack, environment) {
		project.AddToRolePolicy(statement)
	}

	version := awscodepipeline.NewVariable(&awscodepipeline.VariableProps{
		VariableName: jsii.String("VERSION"),
		Description:  jsii.String("Application release version to publish as an AMI (e.g. v1.2.3). Required."),
	})
	healthCheck := awscodepipeline.NewVariable(&awscodepipeline.VariableProps{
		VariableName: jsii.String("HEALTH_CHECK"),
		DefaultValue: jsii.String("true"),
		Description:  jsii.String("true: check that the application starts after the reboot (default). false: skip the health check"),
	})
	verified := awscodepipeline.NewVariable(&awscodepipeline.VariableProps{
		VariableName: jsii.String("VERIFIED"),
		DefaultValue: jsii.String("manual"),
		Description:  jsii.String("How the release was verified: manual (phase 1) or automated (release verification pipeline)"),
	})

	sourceOutput := awscodepipeline.NewArtifact(jsii.String("SourceOutput"), nil)
	pipeline := awscodepipeline.NewPipeline(stack, jsii.String("Pipeline"), &awscodepipeline.PipelineProps{
		PipelineName:             jsii.String(environment.PipelineName()),
		PipelineType:             awscodepipeline.PipelineType_V2,
		ExecutionMode:            awscodepipeline.ExecutionMode_QUEUED,
		ArtifactBucket:           artifactBucket,
		CrossAccountKeys:         jsii.Bool(false),
		RestartExecutionOnUpdate: jsii.Bool(false),
		Variables:                &[]awscodepipeline.Variable{version, healthCheck, verified},
		Stages: &[]*awscodepipeline.StageProps{
			{
				StageName: jsii.String("Source"),
				Actions:   &[]awscodepipeline.IAction{sourceAction(stack, pipelineSettings, sourceOutput)},
			},
			{
				StageName: jsii.String("Publish"),
				Actions: &[]awscodepipeline.IAction{awscodepipelineactions.NewCodeBuildAction(&awscodepipelineactions.CodeBuildActionProps{
					ActionName:         jsii.String("PublishAmi"),
					VariablesNamespace: jsii.String("Publish"),
					Project:            project,
					Input:              sourceOutput,
					EnvironmentVariables: &map[string]*awscodebuild.BuildEnvironmentVariable{
						"VERSION":               {Value: version.Reference()},
						"VERIFIED":              {Value: verified.Reference()},
						"HEALTH_CHECK":          {Value: healthCheck.Reference()},
						"PIPELINE_EXECUTION_ID": {Value: jsii.String("#{codepipeline.PipelineExecutionId}")},
					},
				})},
			},
		},
	})

	output(stack, "PipelineName", pipeline.PipelineName())
	output(stack, "CodeBuildProjectName", project.ProjectName())
	output(stack, "ArtifactBucketName", artifactBucket.BucketName())
	// AMI 公開ツール（Ruby）は、パイプラインのスタック名だけを命名規則で決め、以下の名前はこの出力から引く
	output(stack, "LaunchTemplateStackName", importValue(environment.LaunchTemplateStackExport("StackName")))
	output(stack, "HealthCheckDocumentName", importValue(environment.HealthCheckStackExport("DocumentName")))
	output(stack, "LogGroupName", logGroup.LogGroupName())
	output(stack, "ReleaseInstanceRoleArn", importValue(environment.ReleaseInstanceStackExport("RoleArn")))
	output(stack, "ReleaseInstanceProfileArn", importValue(environment.ReleaseInstanceStackExport("InstanceProfileArn")))
	return stack
}

// sourceAction は、このリポジトリを取得するソースアクション。GitHub（CodeConnections）と CodeCommit に対応する。
// どちらも push による自動起動はしない（パイプラインは担当者が変数 VERSION を指定して起動する）。
func sourceAction(stack awscdk.Stack, settings definitions.PipelineSettings, sourceOutput awscodepipeline.Artifact) awscodepipeline.IAction {
	if settings.SourceTypeOrDefault() == definitions.SourceTypeCodeCommit {
		return awscodepipelineactions.NewCodeCommitSourceAction(&awscodepipelineactions.CodeCommitSourceActionProps{
			ActionName: jsii.String("Source"),
			Repository: awscodecommit.Repository_FromRepositoryName(stack, jsii.String("SourceRepository"),
				jsii.String(settings.SourceRepositoryName)),
			Branch:  jsii.String(settings.SourceBranchName),
			Output:  sourceOutput,
			Trigger: awscodepipelineactions.CodeCommitTrigger_NONE,
		})
	}
	owner, repository, _ := strings.Cut(settings.SourceRepositoryID, "/")
	return awscodepipelineactions.NewCodeStarConnectionsSourceAction(&awscodepipelineactions.CodeStarConnectionsSourceActionProps{
		ActionName:    jsii.String("Source"),
		ConnectionArn: jsii.String(settings.SourceConnectionARN),
		Owner:         jsii.String(owner),
		Repo:          jsii.String(repository),
		Branch:        jsii.String(settings.SourceBranchName),
		Output:        sourceOutput,
		TriggerOnPush: jsii.Bool(false),
	})
}
