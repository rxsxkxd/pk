"""スタックの共通部分。"""

from __future__ import annotations

import aws_cdk as cdk
from constructs import Construct

from ..configuration import Environment


class NamedStack(cdk.Stack):
    """命名規則どおりの名前のスタック。

    - ブートストラップのバージョンの確認（CheckBootstrapVersion）を入れない: cdk bootstrap をしていないアカウントにも、
      AWS CLI でデプロイできるようにする（S3 に置くファイル（asset）を使わないので、ブートストラップは不要）
    - CDKMetadata を入れない: 生成ツールの出力と同じく、テンプレートには定義したリソースだけを入れる
    """

    def __init__(self, scope: Construct, stack_name: str, description: str, environment: Environment) -> None:
        super().__init__(
            scope,
            stack_name,
            stack_name=stack_name,
            description=description,
            env=cdk.Environment(region=environment.aws_region),
            synthesizer=cdk.DefaultStackSynthesizer(generate_bootstrap_version_rule=False),
            analytics_reporting=False,
        )

    def export_output(self, output_id: str, value: str, export_name: str) -> None:
        """命名規則どおりの名前で Export する出力。"""
        cdk.CfnOutput(self, output_id, value=value, export_name=export_name)

    def output(self, output_id: str, value: str) -> None:
        """Export しない出力。"""
        cdk.CfnOutput(self, output_id, value=value)


def import_value(export_name: str) -> str:
    """命名規則どおりの名前の Export を参照する。"""
    return cdk.Fn.import_value(export_name)


def sub(body: str, variables: dict[str, str] | None = None) -> str:
    """Fn::Sub。arn:${AWS::Partition}:... のような ARN を組み立てる。"""
    return cdk.Fn.sub(body, variables)
