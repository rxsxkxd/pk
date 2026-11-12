"""ステップ 2（CloudFront のスタックより先）: CloudFront 用の AWS WAF の web ACL。CloudFront 用の web ACL は us-east-1 に要るので、スタックを分ける。

ルールの順番:
  0. Let's Encrypt の HTTP-01 の確認のパスは、どの国からも通す（EC2 の証明書を HTTP-01 で更新し続けるため）
  1. 許可する国でなく、例外の IP でもない要求を止める
  2〜4. AWS のマネージドルール。waf_managed_rules_mode が count の間は、すべてのルールを Count（記録だけ）にする
ログは us-east-1 の CloudWatch Logs に送る。
"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_logs as logs
from aws_cdk import aws_wafv2 as wafv2
from constructs import Construct

from ..configuration import Configuration
from .common import TerminationStack

ACME_CHALLENGE_PATH = "/.well-known/acme-challenge/"

# マネージドルールグループと、その中のルールの名前（AWS のドキュメントの一覧。2026-11-11 に確かめた）。
# Count に上書きするために、ルールの名前を並べる。AWSManagedIPDDoSList は元から Count なので含めない
MANAGED_RULE_GROUPS: list[tuple[str, list[str]]] = [
    (
        "AWSManagedRulesAmazonIpReputationList",
        ["AWSManagedIPReputationList", "AWSManagedReconnaissanceList"],
    ),
    (
        "AWSManagedRulesCommonRuleSet",
        [
            "NoUserAgent_HEADER",
            "UserAgent_BadBots_HEADER",
            "SizeRestrictions_QUERYSTRING",
            "SizeRestrictions_Cookie_HEADER",
            "SizeRestrictions_BODY",
            "SizeRestrictions_URIPATH",
            "EC2MetaDataSSRF_BODY",
            "EC2MetaDataSSRF_COOKIE",
            "EC2MetaDataSSRF_URIPATH",
            "EC2MetaDataSSRF_QUERYARGUMENTS",
            "GenericLFI_QUERYARGUMENTS",
            "GenericLFI_URIPATH",
            "GenericLFI_BODY",
            "RestrictedExtensions_URIPATH",
            "RestrictedExtensions_QUERYARGUMENTS",
            "GenericRFI_QUERYARGUMENTS",
            "GenericRFI_BODY",
            "GenericRFI_URIPATH",
            "CrossSiteScripting_COOKIE",
            "CrossSiteScripting_QUERYARGUMENTS",
            "CrossSiteScripting_BODY",
            "CrossSiteScripting_URIPATH",
        ],
    ),
    (
        "AWSManagedRulesKnownBadInputsRuleSet",
        [
            "JavaDeserializationRCE_HEADER",
            "JavaDeserializationRCE_BODY",
            "JavaDeserializationRCE_URIPATH",
            "JavaDeserializationRCE_QUERYSTRING",
            "Host_localhost_HEADER",
            "PROPFIND_METHOD",
            "ExploitablePaths_URIPATH",
            "Log4JRCE_HEADER",
            "Log4JRCE_QUERYSTRING",
            "Log4JRCE_BODY",
            "Log4JRCE_URIPATH",
            "ReactJSRCE_BODY",
        ],
    ),
]


def _visibility(metric_name: str) -> wafv2.CfnWebACL.VisibilityConfigProperty:
    return wafv2.CfnWebACL.VisibilityConfigProperty(
        sampled_requests_enabled=True,
        cloud_watch_metrics_enabled=True,
        metric_name=metric_name,
    )


def _not(statement: wafv2.CfnWebACL.StatementProperty) -> wafv2.CfnWebACL.StatementProperty:
    return wafv2.CfnWebACL.StatementProperty(
        not_statement=wafv2.CfnWebACL.NotStatementProperty(statement=statement),
    )


class Step2WafStack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "Step 2 of CloudFront -> EC2: AWS WAF web ACL for the CloudFront distribution. Blocks requests from outside the allowed "
            "countries (with IP exceptions), except the Let's Encrypt HTTP-01 challenge path, and applies "
            "AWS managed rules. Logs go to CloudWatch Logs. Deploy this stack in us-east-1.",
            configuration,
            region="us-east-1",
        )

        # 例外の IP の一覧は、空でも作っておく（例外を足すときに設定値を変えるだけで済むように）
        exception_ip_sets = [
            wafv2.CfnIPSet(
                self,
                f"ExceptionIp{version}Set",
                name=f"{stack_name}-exception-ip{version.lower()}",
                scope="CLOUDFRONT",
                ip_address_version=f"IP{version.upper()}",
                addresses=addresses,
            )
            for version, addresses in (
                ("v4", configuration.waf_exception_ipv4_addresses),
                ("v6", configuration.waf_exception_ipv6_addresses),
            )
        ]

        rules = [
            wafv2.CfnWebACL.RuleProperty(
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
            ),
            # 国が許可されておらず、例外の IP でもないときに止める。例外の IP もマネージドルールは通る
            wafv2.CfnWebACL.RuleProperty(
                name="BlockOutsideAllowedCountries",
                priority=1,
                action=wafv2.CfnWebACL.RuleActionProperty(block={}),
                statement=wafv2.CfnWebACL.StatementProperty(
                    and_statement=wafv2.CfnWebACL.AndStatementProperty(
                        statements=[
                            _not(
                                wafv2.CfnWebACL.StatementProperty(
                                    geo_match_statement=wafv2.CfnWebACL.GeoMatchStatementProperty(
                                        country_codes=configuration.waf_allowed_countries,
                                    ),
                                )
                            ),
                            *[
                                _not(
                                    wafv2.CfnWebACL.StatementProperty(
                                        ip_set_reference_statement=wafv2.CfnWebACL.IPSetReferenceStatementProperty(
                                            arn=ip_set.attr_arn,
                                        ),
                                    )
                                )
                                for ip_set in exception_ip_sets
                            ],
                        ],
                    ),
                ),
                visibility_config=_visibility("BlockOutsideAllowedCountries"),
            ),
        ]

        # 試験の間は、ルールグループ全体ではなく、中のルールを 1 つずつ Count に上書きする（AWS の勧める方法）
        count_only = configuration.waf_managed_rules_mode == "count"
        for offset, (group_name, rule_names) in enumerate(MANAGED_RULE_GROUPS):
            overrides = (
                [
                    wafv2.CfnWebACL.RuleActionOverrideProperty(
                        name=rule_name,
                        action_to_use=wafv2.CfnWebACL.RuleActionProperty(count={}),
                    )
                    for rule_name in rule_names
                ]
                if count_only
                else None
            )
            rules.append(
                wafv2.CfnWebACL.RuleProperty(
                    name=group_name,
                    priority=2 + offset,
                    override_action=wafv2.CfnWebACL.OverrideActionProperty(none={}),
                    statement=wafv2.CfnWebACL.StatementProperty(
                        managed_rule_group_statement=wafv2.CfnWebACL.ManagedRuleGroupStatementProperty(
                            vendor_name="AWS",
                            name=group_name,
                            rule_action_overrides=overrides,
                        ),
                    ),
                    visibility_config=_visibility(group_name),
                )
            )

        web_acl = wafv2.CfnWebACL(
            self,
            "WebAcl",
            name=stack_name,
            scope="CLOUDFRONT",
            description="Allowed countries and IP exceptions, ACME challenge path, AWS managed rules.",
            default_action=wafv2.CfnWebACL.DefaultActionProperty(allow={}),
            visibility_config=_visibility(stack_name),
            rules=rules,
        )

        # ロググループの名前は aws-waf-logs- で始め、web ACL と同じリージョンに置く決まり
        log_group = logs.CfnLogGroup(
            self,
            "WebAclLogGroup",
            log_group_name=f"aws-waf-logs-{stack_name}",
            retention_in_days=configuration.waf_log_retention_days,
        )
        wafv2.CfnLoggingConfiguration(
            self,
            "WebAclLogging",
            resource_arn=web_acl.attr_arn,
            # Fn::GetAtt の Arn は末尾に「:*」が付くので、付かない形を組み立てる
            log_destination_configs=[
                cdk.Fn.sub(
                    "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:${LogGroup}",
                    {"LogGroup": log_group.ref},
                )
            ],
        )

        cdk.CfnOutput(
            self,
            "WebAclArn",
            value=web_acl.attr_arn,
            description="Set this value as cloudfront_web_acl_arn in the configuration file.",
        )
        cdk.CfnOutput(self, "WebAclLogGroupName", value=log_group.ref)
