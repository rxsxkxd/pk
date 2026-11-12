"""SSL/TLS の終端を EC2 の httpd から CloudFront へ移す（CloudFront → EC2）定義の CDK 版（Python）。

設定値ファイルから、3 ステップのうちステップ 1・2 のスタックを定義する（ステップ 3 は AWS CLI）。
cloudfront_certificate_arn が空の間はステップ 2 の CloudFront のスタックを定義せず、そのことを標準エラーに出す。
ALB を使うオプションの構成は、設定値の option_stacks で指定したときだけ定義する。使い方は README.md。
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
