"""再起動後のヘルスチェックのスタック（<app>-<env>-health-check）。"""

from __future__ import annotations

from aws_cdk import aws_iam as iam
from aws_cdk import aws_ssm as ssm
from constructs import Construct

from ..configuration import HEALTH_CHECK_TIMEOUT_SECONDS, Environment
from ..health_check_commands import health_check_commands
from .common import NamedStack, sub


class HealthCheckStack(NamedStack):
    """SSM ドキュメントには L2 の構成要素がないので、L1（CfnDocument）で書く。"""

    def __init__(self, scope: Construct, environment: Environment) -> None:
        super().__init__(
            scope,
            environment.health_check_stack_name,
            f"{environment.application_name} health check (SSM document) for the AMI publish pipeline "
            f"({environment.name})",
            environment,
        )

        document = ssm.CfnDocument(
            self,
            "HealthCheckDocument",
            name=environment.health_check_document_name,
            document_type="Command",
            update_method="NewVersion",
            content={
                "schemaVersion": "2.2",
                "description": "Check that the application responds after the instance reboot",
                "mainSteps": [
                    {
                        "action": "aws:runShellScript",
                        "name": "healthCheck",
                        "inputs": {
                            "timeoutSeconds": str(HEALTH_CHECK_TIMEOUT_SECONDS),
                            "runCommand": health_check_commands(environment),
                        },
                    }
                ],
            },
        )
        # SSM ドキュメントの名前: AMI 公開パイプラインのスタックが参照する（実行の権限の対象）
        self.export_output(
            "HealthCheckDocumentName", document.ref, environment.health_check_stack_export("DocumentName")
        )

        # 既存のロールにアタッチするための、Basic 認証のパラメーターの読み取りの管理ポリシー（生成ツールと同じく残している）
        if name := environment.health_check.basic_auth_parameter_name:
            policy = iam.ManagedPolicy(
                self,
                "BasicAuthParameterReadPolicy",
                description="Attach to the release instance role: read the basic auth parameter for the health check",
                statements=[
                    iam.PolicyStatement(
                        actions=["ssm:GetParameter"],
                        resources=[
                            sub(f"arn:${{AWS::Partition}}:ssm:${{AWS::Region}}:${{AWS::AccountId}}:parameter{name}")
                        ],
                    )
                ],
            )
            self.output(
                "BasicAuthParameterReadPolicyArn",
                policy.managed_policy_arn,
                "Attach this managed policy to the IAM role of the release instance",
            )
