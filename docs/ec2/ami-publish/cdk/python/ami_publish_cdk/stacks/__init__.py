"""AMI 公開パイプラインの仕組みの 4 つのスタックを、CDK（L2 の構成要素）で定義する。

スタック名・リソースの名前・Export の名前は、仕組みの生成ツールと同じ命名規則（configuration.py）で決める。
スタック間の参照は、CDK の自動の参照（名前が自動で決まる Export）を使わず、命名規則どおりの名前の Export と
Fn::ImportValue で行う。AMI 公開ツール（Ruby）がスタック名・出力・Export の名前を前提にしているため。
"""

from constructs import Construct

from ..configuration import Environment
from .health_check import HealthCheckStack
from .launch_template import LaunchTemplateStack
from .pipeline import PipelineStack
from .release_instance import ReleaseInstanceStack


def define_environment(scope: Construct, environment: Environment) -> None:
    """1 環境分の 4 つのスタックを定義する。

    デプロイの順（リリース用インスタンス・ヘルスチェック・起動テンプレート → AMI 公開パイプライン）は、
    Export の参照の順と同じ。CDK のスタックの依存関係としては宣言しない（デプロイは AWS CLI で行うため）。
    """
    ReleaseInstanceStack(scope, environment)
    HealthCheckStack(scope, environment)
    LaunchTemplateStack(scope, environment)
    PipelineStack(scope, environment)
