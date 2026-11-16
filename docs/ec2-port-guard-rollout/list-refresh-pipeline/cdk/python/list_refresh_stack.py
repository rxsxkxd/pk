"""人の作業フローを同じスクリプト・同じ順番で流す、一覧更新パイプライン。

CloudFormation 版とパラメータ・条件・論理 ID・出力をそろえるため、L1 の構成要素で定義する。
既存の YAML は読み込まない。権限を自動で追加する grant や、スクリプトの自動アップロードも使わない。
"""

from __future__ import annotations

import json

import aws_cdk as cdk
from aws_cdk import aws_codebuild as codebuild
from aws_cdk import aws_codepipeline as codepipeline
from aws_cdk import aws_iam as iam
from aws_cdk import aws_logs as logs
from aws_cdk import aws_s3 as s3
from constructs import Construct


CODEBUILD_IMAGE = "aws/codebuild/amazonlinux-x86_64-standard:5.0"

MAKE_BUILDSPEC = {
    "version": 0.2,
    "env": {"shell": "bash"},
    "phases": {
        "build": {
            "commands": [
                "bash fetch-bastion-scripts.sh",
                "bash command/fetch-allow-and-last-lists.sh",
                "bash command/make-jp-lists.sh",
                "bash command/make-aws-lists.sh",
                'FORCE="${FORCE}" bash command/make-refresh.sh',
            ]
        }
    },
    "artifacts": {
        "files": [
            "bastion-scripts-versions.txt",
            "command/publish-refresh-scripts.sh",
            "command/port_guard/refresh-ipv4.sh",
            "command/port_guard/refresh-ipv6.sh",
            "port_guard_whitelists/allow-ipv4.txt",
            "port_guard_whitelists/allow-ipv6.txt",
            "port_guard_whitelists/last-refresh/*.txt",
        ]
    },
}

PUBLISH_BUILDSPEC = {
    "version": 0.2,
    "env": {"shell": "bash"},
    "phases": {
        "build": {
            "commands": [
                "cat bastion-scripts-versions.txt",
                "bash command/publish-refresh-scripts.sh",
            ]
        }
    },
}


def statement(sid: str, actions: str | list[str], resources, **extra) -> dict:
    """IAM の許可。Action の範囲と Resource の範囲は呼び出す側で明示する。"""
    return {"Sid": sid, "Effect": "Allow", "Action": actions, "Resource": resources, **extra}


class ListRefreshPipelineStack(cdk.Stack):
    def __init__(self, scope: Construct, stack_name: str) -> None:
        super().__init__(
            scope,
            stack_name,
            stack_name=stack_name,
            description=(
                "port-guard list refresh pipeline (optional, CDK Python). "
                "Automates the human workflow on the bastion server with the same scripts. "
                "One stack per environment (VPC). Started manually only."
            ),
            synthesizer=cdk.DefaultStackSynthesizer(generate_bootstrap_version_rule=False),
            analytics_reporting=False,
        )

        cdk.CfnParameter(
            self,
            "EnvironmentName",
            type="String",
            allowed_pattern="^[a-z0-9][a-z0-9-]{0,30}$",
            description="Environment (VPC) name. Used in resource names and in the S3 publish location.",
        )
        existing_bucket = cdk.CfnParameter(
            self,
            "PublishBucketName",
            type="String",
            default="",
            description=(
                "Existing bucket of the S3 publish location (the same bucket the human workflow uses). "
                "Leave empty to create a new bucket in this stack (versioning enabled). "
                "An existing bucket must use SSE-S3 (not SSE-KMS) encryption."
            ),
        )
        cdk.CfnParameter(
            self,
            "PublishKeyPrefix",
            type="String",
            default="port-guard",
            allowed_pattern="^[A-Za-z0-9][A-Za-z0-9/_.-]*[A-Za-z0-9]$",
            description="The S3 publish location is s3://<bucket>/<PublishKeyPrefix>/<EnvironmentName>/current.",
        )
        require_approval = cdk.CfnParameter(
            self,
            "RequireApproval",
            type="String",
            default="true",
            allowed_values=["true", "false"],
            description="Insert a manual approval stage (the human check) between making and publishing.",
        )
        retention = cdk.CfnParameter(self, "LogRetentionInDays", type="Number", default=90)
        create_bucket = cdk.CfnCondition(
            self, "CreatePublishBucket", expression=cdk.Fn.condition_equals(existing_bucket.value_as_string, "")
        )
        use_approval = cdk.CfnCondition(
            self, "UseApproval", expression=cdk.Fn.condition_equals(require_approval.value_as_string, "true")
        )

        pipeline_bucket = self._bucket("PipelineBucket", expire_old_versions=True)
        publish_bucket = self._bucket("PublishBucket")
        publish_bucket.cfn_options.condition = create_bucket
        publish_bucket.apply_removal_policy(cdk.RemovalPolicy.RETAIN)
        bucket_name = cdk.Fn.condition_if(
            create_bucket.logical_id, publish_bucket.ref, existing_bucket.value_as_string
        ).to_string()

        def publish_sub(template: str) -> str:
            return cdk.Fn.sub(template, {"Bucket": bucket_name})

        publish_uri = publish_sub("s3://${Bucket}/${PublishKeyPrefix}/${EnvironmentName}/current")
        publish_arn = publish_sub("arn:${AWS::Partition}:s3:::${Bucket}")
        publish_objects = publish_sub(
            "arn:${AWS::Partition}:s3:::${Bucket}/${PublishKeyPrefix}/${EnvironmentName}/current/*"
        )
        pipeline_objects = cdk.Fn.sub("${PipelineBucket.Arn}/*")
        log_group = logs.CfnLogGroup(
            self,
            "BuildLogGroup",
            log_group_name=cdk.Fn.sub("/aws/codebuild/port-guard-list-refresh-${EnvironmentName}"),
            retention_in_days=retention.value_as_number,
        )
        write_logs = statement("WriteLogs", ["logs:CreateLogStream", "logs:PutLogEvents"], log_group.attr_arn)

        # 承認の前に動くビルドは、S3 の公開場所を読む権限だけを持つ。
        make_role = self._role(
            "MakeRole",
            "codebuild.amazonaws.com",
            "CodeBuild that makes the port-guard IP lists and ipset replacement scripts (reads the S3 publish location only)",
            "port-guard-list-refresh-make",
            [
                write_logs,
                statement(
                    "PipelineBucketObjects", ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"], pipeline_objects
                ),
                statement("ReadPublishLocation", "s3:GetObject", publish_objects),
                statement(
                    "ListPublishLocation",
                    "s3:ListBucket",
                    publish_arn,
                    Condition={
                        "StringLike": {"s3:prefix": cdk.Fn.sub("${PublishKeyPrefix}/${EnvironmentName}/current/*")}
                    },
                ),
            ],
        )
        publish_role = self._role(
            "PublishRole",
            "codebuild.amazonaws.com",
            "CodeBuild that publishes the ipset replacement scripts to the S3 publish location (after approval)",
            "port-guard-list-refresh-publish",
            [
                write_logs,
                statement("ReadPipelineArtifacts", ["s3:GetObject", "s3:GetObjectVersion"], pipeline_objects),
                # [変更] この環境の current/ の下だけに書ける。
                statement("WritePublishLocation", "s3:PutObject", publish_objects),
            ],
        )

        make_project = self._project(
            "MakeProject",
            "make",
            "Make the port-guard IP lists and the ipset replacement scripts (same steps as the human workflow)",
            make_role,
            log_group,
            15,
            [
                {"name": "BASTION_SCRIPTS_BUCKET", "value": pipeline_bucket.ref},
                {"name": "BASTION_SCRIPTS_PREFIX", "value": "bastion-scripts"},
                {"name": "PORT_GUARD_S3_URI", "value": publish_uri},
                {"name": "FORCE", "value": "0"},
            ],
            MAKE_BUILDSPEC,
        )
        publish_project = self._project(
            "PublishProject",
            "publish",
            "Publish the ipset replacement scripts to the S3 publish location (same script as the human workflow)",
            publish_role,
            log_group,
            10,
            [{"name": "PORT_GUARD_S3_URI", "value": publish_uri}],
            PUBLISH_BUILDSPEC,
        )
        pipeline_role = self._role(
            "PipelineRole",
            "codepipeline.amazonaws.com",
            "CodePipeline of the port-guard list refresh pipeline",
            "port-guard-list-refresh-pipeline",
            [
                statement(
                    "PipelineBucketObjects", ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"], pipeline_objects
                ),
                statement(
                    "PipelineBucket",
                    ["s3:GetBucketVersioning", "s3:GetBucketLocation", "s3:ListBucket"],
                    pipeline_bucket.attr_arn,
                ),
                statement(
                    "RunBuilds",
                    ["codebuild:StartBuild", "codebuild:BatchGetBuilds"],
                    [make_project.attr_arn, publish_project.attr_arn],
                ),
            ],
        )

        # Fn::If の内側は CloudFormation のプロパティ名（大文字）で書く。
        approval_stage = cdk.Fn.condition_if(
            use_approval.logical_id,
            {
                "Name": "Check",
                "Actions": [
                    {
                        "Name": "HumanCheck",
                        "ActionTypeId": {"Category": "Approval", "Owner": "AWS", "Provider": "Manual", "Version": "1"},
                        "Configuration": {
                            "CustomData": (
                                "Check the make build log (bastion script versions, allow lists fetched, counts, added and "
                                "removed per list) as in the human workflow before approving."
                            )
                        },
                    }
                ],
            },
            cdk.Aws.NO_VALUE,
        )
        pipeline = codepipeline.CfnPipeline(
            self,
            "Pipeline",
            name=cdk.Fn.sub("port-guard-list-refresh-${EnvironmentName}"),
            pipeline_type="V2",
            execution_mode="QUEUED",
            role_arn=pipeline_role.attr_arn,
            artifact_store=codepipeline.CfnPipeline.ArtifactStoreProperty(type="S3", location=pipeline_bucket.ref),
            variables=[codepipeline.CfnPipeline.VariableDeclarationProperty(
                name="FORCE",
                default_value="0",
                description="Set 1 to proceed when a list changed by more than 5% from the last published one (make-refresh.sh FORCE=1)",
            )],
            stages=[
                codepipeline.CfnPipeline.StageDeclarationProperty(
                    name="Source",
                    actions=[codepipeline.CfnPipeline.ActionDeclarationProperty(
                        name="FetchBastionScripts",
                        action_type_id=codepipeline.CfnPipeline.ActionTypeIdProperty(
                            category="Source", owner="AWS", provider="S3", version="1"
                        ),
                        configuration={
                            "S3Bucket": pipeline_bucket.ref,
                            "S3ObjectKey": "source/fetch-bastion-scripts.zip",
                            "PollForSourceChanges": "false",
                        },
                        output_artifacts=[codepipeline.CfnPipeline.OutputArtifactProperty(name="FetchScript")],
                    )],
                ),
                codepipeline.CfnPipeline.StageDeclarationProperty(
                    name="Make",
                    actions=[codepipeline.CfnPipeline.ActionDeclarationProperty(
                        name="MakeListsAndRefreshScripts",
                        action_type_id=codepipeline.CfnPipeline.ActionTypeIdProperty(
                            category="Build", owner="AWS", provider="CodeBuild", version="1"
                        ),
                        configuration={
                            "ProjectName": make_project.ref,
                            "EnvironmentVariables": '[{"name":"FORCE","value":"#{variables.FORCE}","type":"PLAINTEXT"}]',
                        },
                        input_artifacts=[codepipeline.CfnPipeline.InputArtifactProperty(name="FetchScript")],
                        output_artifacts=[codepipeline.CfnPipeline.OutputArtifactProperty(name="MadeFiles")],
                    )],
                ),
                approval_stage,
                codepipeline.CfnPipeline.StageDeclarationProperty(
                    name="Publish",
                    actions=[codepipeline.CfnPipeline.ActionDeclarationProperty(
                        name="PublishRefreshScripts",
                        action_type_id=codepipeline.CfnPipeline.ActionTypeIdProperty(
                            category="Build", owner="AWS", provider="CodeBuild", version="1"
                        ),
                        configuration={"ProjectName": publish_project.ref},
                        input_artifacts=[codepipeline.CfnPipeline.InputArtifactProperty(name="MadeFiles")],
                    )],
                ),
            ],
        )
        cdk.CfnOutput(self, "PipelineName", value=pipeline.ref)
        cdk.CfnOutput(self, "PipelineBucketName", value=pipeline_bucket.ref)
        cdk.CfnOutput(
            self,
            "BastionScriptsUri",
            description="Upload the five bastion scripts (uncompressed) here",
            value=cdk.Fn.sub("s3://${PipelineBucket}/bastion-scripts/command/"),
        )
        cdk.CfnOutput(
            self,
            "FetchScriptZipUri",
            description="Upload fetch-bastion-scripts.zip (only fetch-bastion-scripts.sh) here",
            value=cdk.Fn.sub("s3://${PipelineBucket}/source/fetch-bastion-scripts.zip"),
        )
        cdk.CfnOutput(
            self,
            "PublishLocation",
            description="PORT_GUARD_S3_URI for the human workflow and the pipeline",
            value=publish_uri,
        )

    def _bucket(self, logical_id: str, expire_old_versions: bool = False) -> s3.CfnBucket:
        return s3.CfnBucket(
            self,
            logical_id,
            versioning_configuration=s3.CfnBucket.VersioningConfigurationProperty(status="Enabled"),
            bucket_encryption=s3.CfnBucket.BucketEncryptionProperty(
                server_side_encryption_configuration=[s3.CfnBucket.ServerSideEncryptionRuleProperty(
                    server_side_encryption_by_default=s3.CfnBucket.ServerSideEncryptionByDefaultProperty(
                        sse_algorithm="AES256"
                    )
                )]
            ),
            public_access_block_configuration=s3.CfnBucket.PublicAccessBlockConfigurationProperty(
                block_public_acls=True,
                block_public_policy=True,
                ignore_public_acls=True,
                restrict_public_buckets=True,
            ),
            ownership_controls=s3.CfnBucket.OwnershipControlsProperty(
                rules=[s3.CfnBucket.OwnershipControlsRuleProperty(object_ownership="BucketOwnerEnforced")]
            ),
            lifecycle_configuration=s3.CfnBucket.LifecycleConfigurationProperty(
                rules=[s3.CfnBucket.RuleProperty(
                    id="expire-noncurrent-versions",
                    status="Enabled",
                    noncurrent_version_expiration=s3.CfnBucket.NoncurrentVersionExpirationProperty(noncurrent_days=90),
                )]
            ) if expire_old_versions else None,
        )

    def _role(self, logical_id: str, service: str, description: str, policy_name: str, statements: list[dict]) -> iam.CfnRole:
        return iam.CfnRole(
            self,
            logical_id,
            description=description,
            assume_role_policy_document={
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": service},
                    "Action": "sts:AssumeRole",
                }],
            },
            policies=[iam.CfnRole.PolicyProperty(
                policy_name=policy_name,
                policy_document={"Version": "2012-10-17", "Statement": statements},
            )],
        )

    def _project(
        self,
        logical_id: str,
        suffix: str,
        description: str,
        role: iam.CfnRole,
        log_group: logs.CfnLogGroup,
        timeout: int,
        variables: list[dict],
        buildspec: dict,
    ) -> codebuild.CfnProject:
        return codebuild.CfnProject(
            self,
            logical_id,
            name=cdk.Fn.sub(f"port-guard-list-refresh-${{EnvironmentName}}-{suffix}"),
            description=description,
            service_role=role.attr_arn,
            timeout_in_minutes=timeout,
            artifacts=codebuild.CfnProject.ArtifactsProperty(type="CODEPIPELINE"),
            logs_config=codebuild.CfnProject.LogsConfigProperty(
                cloud_watch_logs=codebuild.CfnProject.CloudWatchLogsConfigProperty(
                    status="ENABLED", group_name=log_group.ref, stream_name=suffix
                )
            ),
            environment=codebuild.CfnProject.EnvironmentProperty(
                type="LINUX_CONTAINER",
                compute_type="BUILD_GENERAL1_SMALL",
                image=CODEBUILD_IMAGE,
                environment_variables=[codebuild.CfnProject.EnvironmentVariableProperty(**variable) for variable in variables],
            ),
            # JSON も YAML として読めるので、追加の YAML ライブラリなしで buildspec を埋め込める。
            source=codebuild.CfnProject.SourceProperty(type="CODEPIPELINE", build_spec=json.dumps(buildspec)),
        )
