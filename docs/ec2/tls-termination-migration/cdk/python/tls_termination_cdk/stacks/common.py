"""スタックの共通部分。"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_certificatemanager as acm
from aws_cdk import aws_cloudfront as cloudfront
from aws_cdk import aws_cloudfront_origins as origins
from constructs import Construct

from ..configuration import Configuration


class TerminationStack(cdk.Stack):
    """構成ごとのスタックの土台。

    - ブートストラップのバージョンの確認を入れない: AWS CLI でデプロイするので、cdk bootstrap を前提にしない
    - CDKMetadata を入れない: テンプレートには定義したリソースだけを入れる
    """

    def __init__(self, scope: Construct, stack_name: str, description: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            stack_name=stack_name,
            description=description,
            env=cdk.Environment(region=configuration.aws_region),
            synthesizer=cdk.DefaultStackSynthesizer(generate_bootstrap_version_rule=False),
            analytics_reporting=False,
        )

    def output(self, output_id: str, value: str, description: str | None = None) -> None:
        cdk.CfnOutput(self, output_id, value=value, description=description)


def origin_verify_header_value(stack: cdk.Stack) -> str:
    """秘密のヘッダーの値。テンプレートに残さないように、デプロイのときのパラメータで受け取る。"""
    parameter = cdk.CfnParameter(
        stack,
        "OriginVerifyHeaderValue",
        type="String",
        no_echo=True,
        min_length=32,
        description="Secret value that the origin checks to reject requests that bypass this distribution.",
    )
    return parameter.value_as_string


def define_distribution(
    scope: Construct,
    configuration: Configuration,
    origin_verify_value: str,
) -> cloudfront.Distribution:
    """CloudFront のディストリビューション。キャッシュせず、利用者の Host などをすべてオリジンへ渡す。"""
    origin = origins.HttpOrigin(
        configuration.origin_domain_name,
        protocol_policy=cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
        origin_ssl_protocols=[cloudfront.OriginSslPolicy.TLS_V1_2],
        read_timeout=cdk.Duration.seconds(configuration.origin_read_timeout_seconds),
        keepalive_timeout=cdk.Duration.seconds(configuration.origin_keepalive_timeout_seconds),
        custom_headers={configuration.origin_verify_header_name: origin_verify_value},
    )
    return cloudfront.Distribution(
        scope,
        "Distribution",
        domain_names=[configuration.domain_name],
        certificate=acm.Certificate.from_certificate_arn(
            scope, "CloudFrontCertificate", configuration.cloudfront_certificate_arn
        ),
        minimum_protocol_version=cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
        http_version=cloudfront.HttpVersion.HTTP2,
        enable_ipv6=False,
        web_acl_id=configuration.cloudfront_web_acl_arn or None,
        default_behavior=cloudfront.BehaviorOptions(
            origin=origin,
            viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
            allowed_methods=cloudfront.AllowedMethods.ALLOW_ALL,
            cached_methods=cloudfront.CachedMethods.CACHE_GET_HEAD,
            cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
            origin_request_policy=cloudfront.OriginRequestPolicy.ALL_VIEWER,
            compress=False,
        ),
    )
