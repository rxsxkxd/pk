"""AMI 公開ツール（Ruby）が CodeBuild 上で使う権限。

仕組みの生成ツールの CodeBuild のロール（Go の internal/definitions の codeBuildServiceRole）と同じ内容。
ただし、ビルドのログ（WriteBuildLogs）とアーティファクトの読み書き（ReadWritePipelineArtifacts）は、
L2 の CodeBuild プロジェクトとパイプラインが自動で付けるので、ここには書かない。
他のスタックのリソースは、命名規則どおりの名前の Export で参照する。
iam:PassRole は PassReleaseInstanceRole の 1 か所だけ（リリース用インスタンスのロールを EC2 に渡す場合だけ）。
"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_iam as iam

from ..configuration import Environment
from .common import import_value, sub


def codebuild_policy_statements(stack: cdk.Stack, environment: Environment) -> list[iam.PolicyStatement]:
    instance_arn = sub(
        f"arn:${{AWS::Partition}}:ec2:${{AWS::Region}}:${{AWS::AccountId}}:instance/{environment.release_instance_id}"
    )
    image_arn = sub("arn:${AWS::Partition}:ec2:${AWS::Region}::image/*")
    snapshot_arn = sub("arn:${AWS::Partition}:ec2:${AWS::Region}::snapshot/*")
    launch_template_stack_name = import_value(environment.launch_template_stack_export("StackName"))
    release_instance_role_arn = import_value(environment.release_instance_stack_export("RoleArn"))

    def statement(sid: str, actions: list[str], resources: list[str], conditions: dict | None = None):
        return iam.PolicyStatement(sid=sid, actions=actions, resources=resources, conditions=conditions)

    any_resource = ["*"]
    return [
        statement("CreateImage", ["ec2:CreateImage"], [instance_arn, image_arn, snapshot_arn]),
        statement("ReadInstanceState", ["ec2:DescribeInstances"], any_resource),
        # リリース用インスタンスのロールの許可の判定（ステップ 0b。対象はそのロールだけ）
        statement("CheckReleaseInstanceRolePermissions", ["iam:SimulatePrincipalPolicy"], [release_instance_role_arn]),
        # ヘルスチェックの区間だけ、リリース用インスタンスにインスタンスプロファイルを紐付ける
        statement(
            "AttachReleaseInstanceProfile",
            ["ec2:AssociateIamInstanceProfile", "ec2:DisassociateIamInstanceProfile"],
            [instance_arn],
        ),
        statement("ReadInstanceProfileAssociations", ["ec2:DescribeIamInstanceProfileAssociations"], any_resource),
        statement(
            "PassReleaseInstanceRole",
            ["iam:PassRole"],
            [release_instance_role_arn],
            {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}},
        ),
        statement("FindBasicAuthParameterKey", ["ssm:DescribeParameters"], any_resource),
        statement("StartStoppedReleaseInstance", ["ec2:StartInstances"], [instance_arn]),
        statement("TagImage", ["ec2:CreateTags"], [image_arn, snapshot_arn]),
        statement("DescribeImagesAndSnapshots", ["ec2:DescribeImages", "ec2:DescribeSnapshots"], any_resource),
        statement(
            "DeleteFailedImage",
            ["ec2:DeregisterImage", "ec2:DeleteSnapshot"],
            [image_arn, snapshot_arn],
            {"StringEquals": {"ec2:ResourceTag/App": environment.application_name}},
        ),
        statement(
            "RunHealthCheck",
            ["ssm:SendCommand"],
            [
                instance_arn,
                sub(
                    "arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:document/${DocumentName}",
                    {"DocumentName": import_value(environment.health_check_stack_export("DocumentName"))},
                ),
            ],
        ),
        statement(
            "ReadCommandAndInstanceStatus", ["ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"], any_resource
        ),
        statement(
            "UpdateLaunchTemplateStack",
            [
                "cloudformation:DescribeStacks",
                "cloudformation:CreateChangeSet",
                "cloudformation:DescribeChangeSet",
                "cloudformation:ExecuteChangeSet",
                "cloudformation:DeleteChangeSet",
            ],
            [
                sub(
                    "arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/${LaunchTemplateStackName}/*",
                    {"LaunchTemplateStackName": launch_template_stack_name},
                )
            ],
        ),
        # CloudFormation のサービスロールを使わず、CodeBuild の権限で変更セットを実行する
        statement(
            "UpdateLaunchTemplate",
            ["ec2:CreateLaunchTemplateVersion", "ec2:ModifyLaunchTemplate"],
            [
                sub(
                    "arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:launch-template/${LaunchTemplateId}",
                    {"LaunchTemplateId": import_value(environment.launch_template_stack_export("LaunchTemplateId"))},
                )
            ],
        ),
        # 起動テンプレートが指すインスタンスプロファイルの確認（名前は「<スタック名>-<論理 ID>-<ランダム>」）
        statement(
            "ReadLaunchTemplateInstanceProfile",
            ["iam:GetInstanceProfile"],
            [
                sub(
                    "arn:${AWS::Partition}:iam::${AWS::AccountId}:instance-profile/${LaunchTemplateStackName}-*",
                    {"LaunchTemplateStackName": launch_template_stack_name},
                )
            ],
        ),
        statement("ReadLaunchTemplates", ["ec2:DescribeLaunchTemplates", "ec2:DescribeLaunchTemplateVersions"], any_resource),
        statement("ReadOwnStackOutputs", ["cloudformation:DescribeStacks"], [stack.stack_id]),
    ]
