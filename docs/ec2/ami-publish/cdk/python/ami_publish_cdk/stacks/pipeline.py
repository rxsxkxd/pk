"""AMI 公開パイプラインのスタック（<app>-<env>-ami-publish-pipeline）。"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_codebuild as codebuild
from aws_cdk import aws_codecommit as codecommit
from aws_cdk import aws_codepipeline as codepipeline
from aws_cdk import aws_codepipeline_actions as actions
from aws_cdk import aws_iam as iam
from aws_cdk import aws_logs as logs
from aws_cdk import aws_s3 as s3
from constructs import Construct

from ..configuration import (
    BUILDSPEC_PATH,
    CODEBUILD_IMAGE,
    CONFIG_FILE_ENVIRONMENT_VARIABLE,
    DEFAULT_CONFIG_PATH,
    SOURCE_TYPE_CODECOMMIT,
    Environment,
)
from .codebuild_permissions import codebuild_policy_statements
from .common import NamedStack, import_value


class PipelineStack(NamedStack):
    """CodePipeline（V2、実行モード QUEUED、変数 VERSION / HEALTH_CHECK / VERIFIED）と CodeBuild プロジェクト、
    アーティファクト用の S3 バケット、ログ用のロググループ。CodeBuild の権限は codebuild_permissions.py。

    L2 の CodePipeline・CodeBuild は、ロールとその基本の権限（S3・ログ・アクションのロール）を自動で作る。
    """

    def __init__(self, scope: Construct, environment: Environment) -> None:
        settings = environment.pipeline
        super().__init__(
            scope,
            environment.pipeline_stack_name,
            f"{environment.application_name} AMI publish pipeline ({environment.name})",
            environment,
        )
        # cfn-lint の検査のうち、意図どおりのものを外す。W6001: 出力の値が他のスタックの Export の Import
        # （AMI 公開ツールが他のスタックの名前を引くため。生成ツールの出力も外している）。
        # W3005: L2 の CodePipeline が足す DependsOn が、GetAtt による依存と重なる（合成の結果に影響しない）
        self.template_options.metadata = {"cfn-lint": {"config": {"ignore_checks": ["W6001", "W3005"]}}}

        # AMI 公開ツールが CodeBuild で読む設定値ファイル。デプロイ時に --parameter-overrides ConfigFile=... で変えられる
        config_file = cdk.CfnParameter(
            self,
            "ConfigFile",
            type="String",
            default=DEFAULT_CONFIG_PATH,
            allowed_pattern=r"^[A-Za-z0-9_][A-Za-z0-9._/-]*\.ya?ml$",
            description="Configuration file read by the AMI publish tool on CodeBuild (relative to the repository root).",
        )

        # 生成ツールの出力と同じく、スタックの削除でバケットとロググループも消す（L2 の既定は残す）。
        # バケットの中身の自動削除（auto_delete_objects）は Lambda を使うので使わない。削除前に中身を空にする
        artifact_bucket = s3.Bucket(
            self,
            "ArtifactBucket",
            encryption=s3.BucketEncryption.S3_MANAGED,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            lifecycle_rules=[s3.LifecycleRule(id="ExpirePipelineArtifacts", expiration=cdk.Duration.days(30))],
            removal_policy=cdk.RemovalPolicy.DESTROY,
        )
        log_group = logs.LogGroup(
            self, "LogGroup", log_group_name=environment.log_group_name, removal_policy=cdk.RemovalPolicy.DESTROY
        )
        # 保存期間は日数の設定値をそのまま使う（L2 の retention は決まった日数の列挙なので、L1 のプロパティで指定する）
        cfn_log_group: logs.CfnLogGroup = log_group.node.default_child
        cfn_log_group.retention_in_days = settings.log_retention_days

        project = codebuild.PipelineProject(
            self,
            "CodeBuildProject",
            project_name=environment.codebuild_project_name,
            description="Create an AMI from the release instance and update the launch template stack",
            # buildspec は仕組みの生成ツールが出力したファイルをそのまま使う
            build_spec=codebuild.BuildSpec.from_source_filename(BUILDSPEC_PATH),
            environment=codebuild.BuildEnvironment(
                build_image=codebuild.LinuxBuildImage.from_code_build_image_id(CODEBUILD_IMAGE),
                compute_type=codebuild.ComputeType.SMALL,
                environment_variables={
                    "AMI_PUBLISH_ENVIRONMENT": codebuild.BuildEnvironmentVariable(value=environment.name),
                    CONFIG_FILE_ENVIRONMENT_VARIABLE: codebuild.BuildEnvironmentVariable(
                        value=config_file.value_as_string
                    ),
                },
            ),
            timeout=cdk.Duration.minutes(environment.codebuild_minutes),
            concurrent_build_limit=1,
            logging=codebuild.LoggingOptions(
                cloud_watch=codebuild.CloudWatchLoggingOptions(log_group=log_group, prefix="codebuild")
            ),
        )
        for statement in codebuild_policy_statements(self, environment):
            project.add_to_role_policy(statement)

        version = codepipeline.Variable(
            variable_name="VERSION",
            description="Application release version to publish as an AMI (e.g. v1.2.3). Required.",
        )
        health_check = codepipeline.Variable(
            variable_name="HEALTH_CHECK",
            default_value="true",
            description="true: check that the application starts after the reboot (default). false: skip the health check",
        )
        verified = codepipeline.Variable(
            variable_name="VERIFIED",
            default_value="manual",
            description="How the release was verified: manual (phase 1) or automated (release verification pipeline)",
        )

        source_output = codepipeline.Artifact("SourceOutput")
        pipeline = codepipeline.Pipeline(
            self,
            "Pipeline",
            pipeline_name=environment.pipeline_name,
            pipeline_type=codepipeline.PipelineType.V2,
            execution_mode=codepipeline.ExecutionMode.QUEUED,
            artifact_bucket=artifact_bucket,
            cross_account_keys=False,
            restart_execution_on_update=False,
            variables=[version, health_check, verified],
            stages=[
                codepipeline.StageProps(
                    stage_name="Source", actions=[self._source_action(environment, source_output)]
                ),
                codepipeline.StageProps(
                    stage_name="Publish",
                    actions=[
                        actions.CodeBuildAction(
                            action_name="PublishAmi",
                            variables_namespace="Publish",
                            project=project,
                            input=source_output,
                            environment_variables={
                                "VERSION": codebuild.BuildEnvironmentVariable(value=version.reference()),
                                "VERIFIED": codebuild.BuildEnvironmentVariable(value=verified.reference()),
                                "HEALTH_CHECK": codebuild.BuildEnvironmentVariable(value=health_check.reference()),
                                "PIPELINE_EXECUTION_ID": codebuild.BuildEnvironmentVariable(
                                    value="#{codepipeline.PipelineExecutionId}"
                                ),
                            },
                        )
                    ],
                ),
            ],
        )
        if settings.source_type != SOURCE_TYPE_CODECOMMIT:
            self._allow_codeconnections(pipeline, settings.source_connection_arn)

        self.output("PipelineName", pipeline.pipeline_name)
        self.output("CodeBuildProjectName", project.project_name)
        self.output("ArtifactBucketName", artifact_bucket.bucket_name)
        # AMI 公開ツール（Ruby）は、パイプラインのスタック名だけを命名規則で決め、以下の名前はこの出力から引く
        self.output("LaunchTemplateStackName", import_value(environment.launch_template_stack_export("StackName")))
        self.output("HealthCheckDocumentName", import_value(environment.health_check_stack_export("DocumentName")))
        self.output("LogGroupName", log_group.log_group_name)
        self.output("ReleaseInstanceRoleArn", import_value(environment.release_instance_stack_export("RoleArn")))
        self.output(
            "ReleaseInstanceProfileArn", import_value(environment.release_instance_stack_export("InstanceProfileArn"))
        )

    @staticmethod
    def _allow_codeconnections(pipeline: codepipeline.Pipeline, connection_arn: str) -> None:
        """ソースのアクションのロールに、新しい接頭辞 codeconnections の UseConnection も許可する。

        L2 は旧来の接頭辞の codestar-connections:UseConnection だけを付ける。生成ツールと同じく両方を許可する。
        ソースのアクションのロールは、L2 がパイプラインの中に作る（パス: Pipeline/Source/Source/CodePipelineActionRole）。
        """
        role = (
            pipeline.node.find_child("Source").node.find_child("Source").node.find_child("CodePipelineActionRole")
        )
        role.add_to_principal_policy(
            iam.PolicyStatement(actions=["codeconnections:UseConnection"], resources=[connection_arn])
        )

    def _source_action(self, environment: Environment, source_output: codepipeline.Artifact) -> codepipeline.IAction:
        """このリポジトリを取得するソースアクション。GitHub（CodeConnections）と CodeCommit に対応する。

        どちらも push による自動起動はしない（パイプラインは担当者が変数 VERSION を指定して起動する）。
        """
        settings = environment.pipeline
        if settings.source_type == SOURCE_TYPE_CODECOMMIT:
            return actions.CodeCommitSourceAction(
                action_name="Source",
                repository=codecommit.Repository.from_repository_name(
                    self, "SourceRepository", settings.source_repository_name
                ),
                branch=settings.source_branch_name,
                output=source_output,
                trigger=actions.CodeCommitTrigger.NONE,
            )
        owner, _, repository = settings.source_repository_id.partition("/")
        return actions.CodeStarConnectionsSourceAction(
            action_name="Source",
            connection_arn=settings.source_connection_arn,
            owner=owner,
            repo=repository,
            branch=settings.source_branch_name,
            output=source_output,
            trigger_on_push=False,
        )
