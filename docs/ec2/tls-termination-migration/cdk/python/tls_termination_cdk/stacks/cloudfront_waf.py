"""CloudFront 用の AWS WAF の web ACL。CloudFront 用の web ACL は us-east-1 に要るので、スタックを分ける。

許可する国以外からの要求を止める。ただし、Let's Encrypt の HTTP-01 の確認のパスだけは、どの国からも通す
（EC2 の Let's Encrypt の証明書を、CloudFront 経由の HTTP-01 で更新し続けるため）。
"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_wafv2 as wafv2
from constructs import Construct

from ..configuration import Configuration
from .common import TerminationStack

ACME_CHALLENGE_PATH = "/.well-known/acme-challenge/"


def _visibility(metric_name: str) -> wafv2.CfnWebACL.VisibilityConfigProperty:
    return wafv2.CfnWebACL.VisibilityConfigProperty(
        sampled_requests_enabled=True,
        cloud_watch_metrics_enabled=True,
        metric_name=metric_name,
    )


class CloudFrontWafStack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "AWS WAF web ACL for the CloudFront distribution. Blocks requests from outside the allowed "
            "countries, except the Let's Encrypt HTTP-01 challenge path. Deploy this stack in us-east-1.",
            configuration,
            region="us-east-1",
        )

        allow_acme_challenge = wafv2.CfnWebACL.RuleProperty(
            name="AllowAcmeChallenge",
            priority=0,
            action=wafv2.CfnWebACL.RuleActionProperty(allow={}),
            statement=wafv2.CfnWebACL.StatementProperty(
                byte_match_statement=wafv2.CfnWebACL.ByteMatchStatementProperty(
                    field_to_match=wafv2.CfnWebACL.FieldToMatchProperty(uri_path={}),
                    positional_constraint="STARTS_WITH",
                    search_string=ACME_CHALLENGE_PATH,
                    # 「..」や「%2e%2e」で確認のパスの外へ出られないよう、デコードしてから正規化して比べる
                    text_transformations=[
                        wafv2.CfnWebACL.TextTransformationProperty(priority=0, type="URL_DECODE"),
                        wafv2.CfnWebACL.TextTransformationProperty(priority=1, type="NORMALIZE_PATH"),
                    ],
                ),
            ),
            visibility_config=_visibility("AllowAcmeChallenge"),
        )
        block_outside_allowed_countries = wafv2.CfnWebACL.RuleProperty(
            name="BlockOutsideAllowedCountries",
            priority=1,
            action=wafv2.CfnWebACL.RuleActionProperty(block={}),
            statement=wafv2.CfnWebACL.StatementProperty(
                not_statement=wafv2.CfnWebACL.NotStatementProperty(
                    statement=wafv2.CfnWebACL.StatementProperty(
                        geo_match_statement=wafv2.CfnWebACL.GeoMatchStatementProperty(
                            country_codes=configuration.waf_allowed_countries,
                        ),
                    ),
                ),
            ),
            visibility_config=_visibility("BlockOutsideAllowedCountries"),
        )

        web_acl = wafv2.CfnWebACL(
            self,
            "WebAcl",
            name=stack_name,
            scope="CLOUDFRONT",
            description="Allowed countries only, except the ACME HTTP-01 challenge path.",
            default_action=wafv2.CfnWebACL.DefaultActionProperty(allow={}),
            visibility_config=_visibility(stack_name),
            rules=[allow_acme_challenge, block_outside_allowed_countries],
        )
        cdk.CfnOutput(
            self,
            "WebAclArn",
            value=web_acl.attr_arn,
            description="Set this value as cloudfront_web_acl_arn in the configuration file.",
        )
