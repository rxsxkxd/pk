"""AMI 公開パイプラインの仕組みの CDK 版（Python）。

設定値ファイル（config/ami_publish.yml）の全環境について、4 つのスタックを定義する。
CDK は CloudFormation テンプレートを作る（cdk synth）ためだけに使い、デプロイは今までどおり担当者が
AWS CLI で変更セットを作って確認してから反映する（決定事項 D9。cdk bootstrap は不要）。
L2 の構成要素で書くので、論理 ID は仕組みの生成ツール（Go の cmd/generate-definitions）の出力と異なる。
そのため、生成ツールでデプロイ済みの環境を、このテンプレートで更新しない（新しい環境向け）。

    cd cdk/python && cdk synth                       # cdk.out/ に全環境のテンプレートを出力する
    cdk synth -c config=../../config/other.yml       # 設定値ファイルを変える
"""

import sys

import aws_cdk as cdk

from ami_publish_cdk.configuration import ConfigurationError, load_configuration
from ami_publish_cdk.stacks import define_environment


def main() -> None:
    app = cdk.App()
    config_path = app.node.try_get_context("config") or "../../config/ami_publish.yml"
    try:
        configuration = load_configuration(config_path)
    except ConfigurationError as error:
        print(error, file=sys.stderr)
        sys.exit(2)

    for environment in configuration.environments:
        define_environment(app, environment)
    app.synth()


if __name__ == "__main__":
    main()
