"""ステップ 2（CloudFront のスタックより先）: CloudFront 用の AWS WAF の web ACL。

CloudFront 用の web ACL（スコープ CLOUDFRONT）は us-east-1 に作る決まりなので、CloudFront のスタック
（aws_region）とは別のスタックにする。

ルールは 2 つだけ（国の絞り込み）。評価は優先順位の小さい順で、どれにも当たらなければ通す（既定の動作）。
  0. AllowAcmeChallenge: Let's Encrypt の HTTP-01 の確認のパスは、どの国からも通す
  1. BlockOutsideAllowedCountries: 許可する国でなく、例外の IP でもない要求を止める

AWS のマネージドルールとログは、既定では入れない（2026-11-13 に決めた）。入れ方と、入れていたときの
設定値は options/waf-managed-rules.md（オプション）。
"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_wafv2 as wafv2
from constructs import Construct

from ..configuration import Configuration
from .common import TerminationStack

# Let's Encrypt が HTTP-01 で確認に来るパス。オリジンの証明書（EC2 の Let's Encrypt）を、CloudFront 経由で
# 更新し続けるために、このパスだけは国で絞らない
ACME_CHALLENGE_PATH = "/.well-known/acme-challenge/"


def _visibility(metric_name: str) -> wafv2.CfnWebACL.VisibilityConfigProperty:
    """CloudWatch のメトリクスとサンプルの要求の設定。

    WAF の決まりで、どのルールにも web ACL にも必須なので、同じ形をここにまとめる。
    メトリクスの名前はルールの名前と同じにする（メトリクスとサンプルで、どのルールに当たったかが分かる）。
    """
    return wafv2.CfnWebACL.VisibilityConfigProperty(
        sampled_requests_enabled=True,
        cloud_watch_metrics_enabled=True,
        metric_name=metric_name,
    )


def _not(statement: wafv2.CfnWebACL.StatementProperty) -> wafv2.CfnWebACL.StatementProperty:
    """条件を否定する（NotStatement で包む）。"""
    return wafv2.CfnWebACL.StatementProperty(
        not_statement=wafv2.CfnWebACL.NotStatementProperty(statement=statement),
    )


class Step2WafStack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        # 説明（英語）はテンプレートに出る。日本語のコメントはテンプレートに出ない
        super().__init__(
            scope,
            stack_name,
            "Step 2 of CloudFront -> EC2: AWS WAF web ACL for the CloudFront distribution. Blocks requests from outside the allowed "
            "countries (with IP exceptions), except the Let's Encrypt HTTP-01 challenge path. "
            "Deploy this stack in us-east-1.",
            configuration,
            region="us-east-1",
        )

        # 例外の IP の一覧。WAF のルールには IP を直接書けないので、IP セットを別に作って ARN で参照する。
        # 1 つの IP セットには IPv4 か IPv6 の一方しか入れられないので、2 つ作る。
        # 空でも作っておく（例外を足すときに、設定値を変えて更新するだけで済むように）
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
            # 0. 確認のパスは、どの国からも通す。Let's Encrypt は複数の国から確認に来るため。
            #    Allow はそこで評価を終えるので、この要求には次の国の絞り込みが効かない
            wafv2.CfnWebACL.RuleProperty(
                name="AllowAcmeChallenge",
                priority=0,
                action=wafv2.CfnWebACL.RuleActionProperty(allow={}),
                statement=wafv2.CfnWebACL.StatementProperty(
                    byte_match_statement=wafv2.CfnWebACL.ByteMatchStatementProperty(
                        field_to_match=wafv2.CfnWebACL.FieldToMatchProperty(uri_path={}),
                        positional_constraint="STARTS_WITH",
                        search_string=ACME_CHALLENGE_PATH,
                        # 「/.well-known/acme-challenge/../../admin」や「%2e%2e」のように、確認のパスで始めて
                        # 外へ出る要求を通さないよう、URL のデコード → パスの正規化（.. を解く）の順に変換してから比べる
                        text_transformations=[
                            wafv2.CfnWebACL.TextTransformationProperty(priority=0, type="URL_DECODE"),
                            wafv2.CfnWebACL.TextTransformationProperty(priority=1, type="NORMALIZE_PATH"),
                        ],
                    ),
                ),
                visibility_config=_visibility("AllowAcmeChallenge"),
            ),
            # 1. 国が許可されておらず、例外の IP でもないときに止める（CloudFront が 403 を返す）。
            #    WAF には「止める。ただしこの IP は除く」という書き方がないので、
            #    「許可する国でない」かつ「IPv4 の例外でない」かつ「IPv6 の例外でない」を NOT と AND で組む。
            #    国は、CloudFront に接続した送り元の IP で判定する（X-Forwarded-For は使わない）
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
                            # IPv4 と IPv6 の例外の一覧を、1 つずつ否定して並べる
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

        # 既定の動作は「通す」。上の 2 つのルールのどちらにも当たらない要求（許可する国か、例外の IP から来た要求）は通る
        web_acl = wafv2.CfnWebACL(
            self,
            "WebAcl",
            name=stack_name,
            scope="CLOUDFRONT",
            description="Allowed countries and IP exceptions, ACME challenge path.",
            default_action=wafv2.CfnWebACL.DefaultActionProperty(allow={}),
            visibility_config=_visibility(stack_name),
            rules=rules,
        )

        # ステップ 2 の CloudFront のスタックに渡す値。設定値ファイルの cloudfront_web_acl_arn に書く
        cdk.CfnOutput(
            self,
            "WebAclArn",
            value=web_acl.attr_arn,
            description="Set this value as cloudfront_web_acl_arn in the configuration file.",
        )
