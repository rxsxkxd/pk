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
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "Step 1 of CloudFront -> EC2: ACM certificate for the viewer domain name of CloudFront. "
            "Deploy this stack in us-east-1.",
            configuration,
            region="us-east-1",
        )

        if configuration.certificate_hosted_zone_id:
            zone = route53.HostedZone.from_hosted_zone_id(self, "Zone", configuration.certificate_hosted_zone_id)
            validation = acm.CertificateValidation.from_dns(zone)
        else:
            # ゾーンを指定しないときは、ACM が示す検証用の CNAME を、スタックの作成中に DNS へ足す
            validation = acm.CertificateValidation.from_dns()

        certificate = acm.Certificate(
            self,
            "Certificate",
            domain_name=configuration.domain_name,
            validation=validation,
        )
        cdk.CfnOutput(
            self,
            "CertificateArn",
            value=certificate.certificate_arn,
            description="Set this value as cloudfront_certificate_arn in the configuration file (step 2).",
        )
