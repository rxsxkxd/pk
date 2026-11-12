"""SSL/TLS の終端を前段へ移す 3 つの構成の CDK 版（Python）。

設定値ファイルから各構成のスタックを定義する。同じ環境にデプロイする構成は 1 つだけ。
証明書の ARN が空のスタックは定義せず、その名前を標準エラーに出す。使い方は README.md。
CDK は CloudFormation テンプレートを作る（cdk synth）ためだけに使い、デプロイは担当者が AWS CLI で
変更セットを作って確認してから反映する（cdk bootstrap は不要）。

    cd cdk/python && cdk synth                     # cdk.out/ にテンプレートを出力する
    cdk synth -c config=config.yml                 # 設定値ファイルを変える
"""

import sys

import aws_cdk as cdk

from tls_termination_cdk.configuration import ConfigurationError, load_configuration
from tls_termination_cdk.stacks import define_stacks


def main() -> None:
    app = cdk.App()
    config_path = app.node.try_get_context("config") or "config.example.yml"
    try:
        configuration = load_configuration(config_path)
    except ConfigurationError as error:
        print(error, file=sys.stderr)
        sys.exit(2)

    skipped = define_stacks(app, configuration)
    for stack in skipped:
        print(f"定義しなかったスタック: {stack}", file=sys.stderr)
    app.synth()


if __name__ == "__main__":
    main()
