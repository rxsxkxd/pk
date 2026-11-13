"""SSL/TLS の終端を EC2 の httpd から CloudFront へ移す（CloudFront → EC2）定義の CDK 版（Python）。

設定値ファイルから、3 ステップのうちステップ 1・2 のスタックを定義する（ステップ 3 は AWS CLI）。
cloudfront_certificate_arn が空の間はステップ 2 の CloudFront のスタックを定義せず、そのことを標準エラーに出す。
ALB を使うオプションの構成は、設定値の option_stacks で指定したときだけ定義する。使い方は README.md。
デプロイは、cdk deploy で直接反映するか、cdk synth で出したテンプレートを AWS CLI で反映する
（どちらも cdk bootstrap はしない。アセットがなく、テンプレートが小さいため）。

    cd cdk/python && cdk synth                     # cdk.out/ にテンプレートを出力する
    cdk synth -c config=config.yml                 # 設定値ファイルを変える
"""

import sys

import aws_cdk as cdk

from tls_termination_cdk.configuration import ConfigurationError, load_configuration
from tls_termination_cdk.stacks import define_stacks


def main() -> None:
    # cdk.App は、cdk の CLI から渡されたコンテキスト（-c config=...）と出力先（cdk.out/）を環境変数から受け取る。
    # cdk の CLI を使わないときは、CDK_CONTEXT_JSON と CDK_OUTDIR を自分で渡す（README.md の合成）
    app = cdk.App()
    # 設定値ファイル。指定がなければ例（架空の値）を使う。cdk.json の context にも同じ既定値を書いている
    config_path = app.node.try_get_context("config") or "config.example.yml"
    try:
        configuration = load_configuration(config_path)
    except ConfigurationError as error:
        print(error, file=sys.stderr)
        sys.exit(2)

    skipped = define_stacks(app, configuration)
    # 定義しなかった本線のスタックは、エラーにせず標準エラーに知らせるだけにする（ステップ 1 の前は正常なため）。
    # 標準出力には出さない（cdk synth <スタック名> の標準出力は、テンプレートの YAML そのものなので）
    for stack in skipped:
        print(f"定義しなかったスタック: {stack}", file=sys.stderr)
    # cdk.out/ にテンプレート（<スタック名>.template.json）と、cdk の CLI が読む manifest.json などを書き出す
    app.synth()


if __name__ == "__main__":
    main()
