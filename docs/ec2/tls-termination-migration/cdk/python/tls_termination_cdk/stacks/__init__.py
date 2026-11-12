"""3 つの構成のスタックの定義。"""

from __future__ import annotations

from constructs import Construct

from ..configuration import Configuration
from .alb_to_ec2 import AlbToEc2Stack
from .cloudfront_alb_to_ec2 import CloudFrontAlbToEc2Stack
from .cloudfront_certificate import CloudFrontCertificateStack
from .cloudfront_to_ec2 import CloudFrontToEc2Stack
from .cloudfront_to_ec2_same_domain import CloudFrontToEc2SameDomainStack
from .cloudfront_waf import CloudFrontWafStack


def define_stacks(scope: Construct, configuration: Configuration) -> list[str]:
    """スタックを定義し、証明書の ARN がなくて定義しなかったスタックの名前と理由を返す。

    CloudFront の証明書と WAF のスタックは、ほかのスタックに要る ARN を作る側なので、いつも定義する。
    """
    prefix = configuration.stack_name_prefix
    skipped: list[str] = []

    CloudFrontCertificateStack(scope, f"{prefix}-cloudfront-certificate", configuration)
    CloudFrontWafStack(scope, f"{prefix}-cloudfront-waf", configuration)

    has_alb = bool(configuration.alb_certificate_arn)
    has_cloudfront = bool(configuration.cloudfront_certificate_arn)

    if has_alb:
        AlbToEc2Stack(scope, f"{prefix}-alb-to-ec2", configuration)
    else:
        skipped.append(f"{prefix}-alb-to-ec2（alb_certificate_arn が空）")

    if has_cloudfront:
        CloudFrontToEc2Stack(scope, f"{prefix}-cloudfront-to-ec2", configuration)
        CloudFrontToEc2SameDomainStack(scope, f"{prefix}-cloudfront-to-ec2-same-domain", configuration)
    else:
        skipped.append(f"{prefix}-cloudfront-to-ec2（cloudfront_certificate_arn が空）")
        skipped.append(f"{prefix}-cloudfront-to-ec2-same-domain（cloudfront_certificate_arn が空）")

    if has_alb and has_cloudfront:
        CloudFrontAlbToEc2Stack(scope, f"{prefix}-cloudfront-alb-to-ec2", configuration)
    else:
        skipped.append(f"{prefix}-cloudfront-alb-to-ec2（alb_certificate_arn と cloudfront_certificate_arn の両方が要る）")

    return skipped
