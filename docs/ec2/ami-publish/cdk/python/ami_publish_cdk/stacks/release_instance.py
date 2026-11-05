"""リリース用インスタンスの IAM ロールのスタック（<app>-<env>-release-instance）。"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_iam as iam
from constructs import Construct

from ..configuration import Environment
from .common import NamedStack, sub


class ReleaseInstanceStack(NamedStack):
    """リリース用インスタンスに、ヘルスチェックの区間だけ紐付けるロールとインスタンスプロファイル。

    許可は A（AmazonSSMManagedInstanceCore）、B（ヘルスチェックの出力を CloudWatch Logs に送る）、
    C（Basic 認証のパラメーターの読み取り。設定したときだけ）。紐付けは AMI 公開ツールが行う。
    """

    def __init__(self, scope: Construct, environment: Environment) -> None:
        super().__init__(
            scope,
            environment.release_instance_stack_name,
            f"{environment.application_name} release instance IAM role for the AMI publish pipeline "
            f"({environment.name})",
            environment,
        )

        statements = [
            iam.PolicyStatement(
                sid="WriteHealthCheckOutput",
                actions=["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
                resources=[
                    sub(
                        "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:"
                        f"{environment.log_group_name}:*"
                    )
                ],
            ),
            iam.PolicyStatement(sid="FindLogGroup", actions=["logs:DescribeLogGroups"], resources=["*"]),
        ]
        if name := environment.health_check.basic_auth_parameter_name:
            statements.append(
                iam.PolicyStatement(
                    sid="ReadBasicAuthParameter",
                    actions=["ssm:GetParameter"],
                    resources=[sub(f"arn:${{AWS::Partition}}:ssm:${{AWS::Region}}:${{AWS::AccountId}}:parameter{name}")],
                )
            )

        role = iam.Role(
            self,
            "ReleaseInstanceRole",
            description="Role of the release instance (the source of the AMI): SSM and the health check",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[iam.ManagedPolicy.from_aws_managed_policy_name("AmazonSSMManagedInstanceCore")],
            inline_policies={"health-check": iam.PolicyDocument(statements=statements)},
        )
        cdk.Tags.of(role).add("App", environment.application_name)
        profile = iam.InstanceProfile(self, "ReleaseInstanceProfile", role=role)

        # AMI 公開パイプラインのスタックが参照する（AMI 公開ツールがヘルスチェックの区間だけ紐付ける）
        self.export_output(
            "InstanceProfileArn",
            profile.instance_profile_arn,
            environment.release_instance_stack_export("InstanceProfileArn"),
        )
        self.export_output("RoleArn", role.role_arn, environment.release_instance_stack_export("RoleArn"))
        self.output("InstanceProfileName", profile.instance_profile_name)
        self.output("RoleName", role.role_name)
