"""ステップ 1: CloudFront の証明書（ACM で作成する場合）。CloudFront の証明書は us-east-1 に要るので、スタックを分ける。

既存の証明書を ACM に登録（インポート）する場合は、このスタックを使わず AWS CLI で行う（CloudFormation は登録に対応していない）。
"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_certificatemanager as acm
from aws_cdk import aws_route53 as route53
from constructs import Construct

from ..configuration import Configuration
from .common import TerminationStack


class Step1CertificateStack(TerminationStack):
    """利用者のドメイン名の証明書を、ACM に DNS 検証で作成してもらうスタック。出力は CertificateArn。"""

    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "Step 1 of CloudFront -> EC2: ACM certificate for the viewer domain name of CloudFront. "
            "Deploy this stack in us-east-1.",
            configuration,
            region="us-east-1",
        )

        # 検証用の CNAME の足し方。ホストゾーンを指定すれば CloudFormation が Route 53 に自動で作る（ステージング）。
        # どちらの場合も、CloudFormation のプロパティ（DomainValidationOptions）で表すだけで、Lambda などは使わない
        if configuration.certificate_hosted_zone_id:
            zone = route53.HostedZone.from_hosted_zone_id(self, "Zone", configuration.certificate_hosted_zone_id)
            validation = acm.CertificateValidation.from_dns(zone)
        else:
            # ゾーンを指定しないときは、ACM が示す検証用の CNAME を、スタックの作成中に DNS へ足す
            validation = acm.CertificateValidation.from_dns()

        # ACM の「証明書」（通常の公開証明書）を作る。「ACME 証明書」ではない（ACME 証明書は CloudFront に付けられない）。
        # ACM は、検証用の CNAME が残っていて証明書が使われている間、自動で更新する
        certificate = acm.Certificate(
            self,
            "Certificate",
            domain_name=configuration.domain_name,
            validation=validation,
        )
        # ステップ 2 の設定値 cloudfront_certificate_arn に書く値
        cdk.CfnOutput(
            self,
            "CertificateArn",
            value=certificate.certificate_arn,
            description="Set this value as cloudfront_certificate_arn in the configuration file (step 2).",
        )
