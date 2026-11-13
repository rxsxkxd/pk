"""ステップ 2: CloudFront → EC2（利用者のドメイン名を変えない）の CloudFront とオリジン用のセキュリティグループ。

利用者のドメイン名の DNS のレコードは、ステップ 3 で AWS CLI で変える（ここでは作らない）。
"""

from __future__ import annotations

from aws_cdk import aws_route53 as route53
from constructs import Construct

from ..configuration import Configuration
from .common import (
    TerminationStack,
    define_distribution,
    define_origin_security_group,
    origin_verify_header_value,
)


class Step2CloudFrontStack(TerminationStack):
    """CloudFront、オリジン用のセキュリティグループ、（ステージングでは）オリジンの名前の A レコード。

    設定値の cloudfront_certificate_arn（ステップ 1 の出力）があるときだけ定義する（stacks/__init__.py）。
    """

    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "Step 2 of CloudFront -> EC2 with the viewer domain name unchanged. CloudFront terminates viewer TLS and connects "
            "to httpd over HTTPS through a separate origin DNS name, keeping the viewer Host header.",
            configuration,
        )

        # オリジンの名前（origin.app.example.com → 稼働サーバーの Elastic IP）。ホストゾーンを指定したとき
        # （Route 53。ステージング）だけ作る。外部の DNS サービス（本番）では手で足す
        if configuration.origin_hosted_zone_id:
            # 利用者のドメイン名のレコードは既にあるので、ここでは作らない。ステップ 3 で担当者が切り替える
            route53.CfnRecordSet(
                self,
                "OriginRecord",
                hosted_zone_id=configuration.origin_hosted_zone_id,
                name=configuration.origin_domain_name,
                type="A",
                ttl="300",
                resource_records=[configuration.origin_elastic_ip],
            )

        origin_security_group = define_origin_security_group(self, configuration)
        # 秘密のヘッダーの値はパラメータ（OriginVerifyHeaderValue）で受け取り、CloudFront のオリジンの設定に入れる
        distribution = define_distribution(
            self, configuration, origin_verify_header_value(self), configuration.geo_restriction_countries
        )

        # ステップ 2 の確認（curl --connect-to の接続先）と、ステップ 3 の向き先に使う
        self.output(
            "DistributionDomainName",
            distribution.distribution_domain_name,
            "Step 3: point domain_name to this name after checking the distribution.",
        )
        # ステップ 2 の 2-4 で、稼働サーバーに足すセキュリティグループ
        self.output(
            "OriginSecurityGroupId",
            origin_security_group.security_group_id,
            "Add this security group to the instance before checking the distribution (step 2).",
        )
