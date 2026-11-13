"""スタックの定義。

本線は CloudFront → EC2 の 3 ステップ。ステップ 3（DNS の向き先の変更）は AWS CLI で行うので、スタックはない。

    ステップ 1  <prefix>-step1-certificate   us-east-1   ACM の証明書（作成する場合）
    ステップ 2  <prefix>-step2-waf           us-east-1   CloudFront 用の WAF の web ACL
                <prefix>-step2-cloudfront    aws_region  CloudFront、オリジン用のセキュリティグループ

オプションの構成（ALB を使う構成）は、設定値の option_stacks で指定したときだけ定義する。
"""

from __future__ import annotations

from constructs import Construct

from ..configuration import Configuration
from .options.alb_to_ec2 import AlbToEc2Stack
from .options.cloudfront_alb_to_ec2 import CloudFrontAlbToEc2Stack
from .step1_certificate import Step1CertificateStack
from .step2_cloudfront import Step2CloudFrontStack
from .step2_waf import Step2WafStack

# option_stacks に書く名前と、そのスタックのクラス。名前は configuration.py の OPTION_REQUIRED_KEYS と同じにする
OPTION_STACKS = {
    "alb-to-ec2": AlbToEc2Stack,
    "cloudfront-alb-to-ec2": CloudFrontAlbToEc2Stack,
}


def define_stacks(scope: Construct, configuration: Configuration) -> list[str]:
    """スタックを定義し、定義しなかった本線のスタックの名前と理由を返す。"""
    prefix = configuration.stack_name_prefix
    skipped: list[str] = []

    # スタックの構築 ID（第 2 引数）はスタック名と同じにする。cdk deploy <スタック名> や
    # cdk.out/<スタック名>.template.json で、そのまま指定できるように

    # ステップ 1 とステップ 2 の WAF は、ステップ 2 の CloudFront に要る ARN を作る側なので、いつも定義する
    Step1CertificateStack(scope, f"{prefix}-step1-certificate", configuration)
    Step2WafStack(scope, f"{prefix}-step2-waf", configuration)

    # CloudFront の証明書の ARN（ステップ 1 の出力）がないと CloudFront を作れないので、それまでは定義しない
    if configuration.cloudfront_certificate_arn:
        Step2CloudFrontStack(scope, f"{prefix}-step2-cloudfront", configuration)
    else:
        skipped.append(f"{prefix}-step2-cloudfront（cloudfront_certificate_arn が空。ステップ 1 の後に書く）")

    # オプションの構成は、書かれたものだけを定義する（名前の誤りは configuration.py で止めている）
    for option in configuration.option_stacks:
        OPTION_STACKS[option](scope, f"{prefix}-option-{option}", configuration)

    return skipped
