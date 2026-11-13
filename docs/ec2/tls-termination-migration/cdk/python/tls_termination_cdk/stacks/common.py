"""スタックの共通部分。

本線（ステップ 1・2）とオプションの構成で共用する部品を置く。
  TerminationStack                スタックの土台（ブートストラップを前提にしない設定）
  origin_verify_header_value      秘密のヘッダーの値を受け取るパラメータ
  define_origin_security_group    CloudFront から稼働サーバーの 443 番への接続を許可するセキュリティグループ
  define_distribution             CloudFront のディストリビューション（キャッシュしない設定）
"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_certificatemanager as acm
from aws_cdk import aws_cloudfront as cloudfront
from aws_cdk import aws_cloudfront_origins as origins
from aws_cdk import aws_ec2 as ec2
from constructs import Construct

from ..configuration import Configuration


class TerminationStack(cdk.Stack):
    """構成ごとのスタックの土台。

    - ブートストラップのバージョンの確認を入れない: cdk bootstrap を前提にしない（AWS CLI でも cdk deploy でも反映できるように）
    - CDKMetadata を入れない: テンプレートには定義したリソースだけを入れる
    """

    def __init__(
        self,
        scope: Construct,
        stack_name: str,
        description: str,
        configuration: Configuration,
        region: str | None = None,
    ) -> None:
        # region を渡さないスタックは、設定値の aws_region に置く。アカウントは指定しない
        # （デプロイに使う認証情報のアカウントになる）
        super().__init__(
            scope,
            stack_name,
            stack_name=stack_name,
            description=description,
            env=cdk.Environment(region=region or configuration.aws_region),
            # テンプレートに Rules の CheckBootstrapVersion とパラメータ BootstrapVersion を入れない
            synthesizer=cdk.DefaultStackSynthesizer(generate_bootstrap_version_rule=False),
            # テンプレートに CDKMetadata（CDK の利用状況を AWS に送るリソース）を入れない
            analytics_reporting=False,
        )

    def output(self, output_id: str, value: str, description: str | None = None) -> None:
        """スタックの出力（Outputs）を足す。次のステップに渡す値（ARN など）に使う。"""
        cdk.CfnOutput(self, output_id, value=value, description=description)


def origin_verify_header_value(stack: cdk.Stack) -> str:
    """秘密のヘッダーの値。テンプレートに残さないように、デプロイのときのパラメータで受け取る。

    NoEcho にするので、describe-stacks などでは値が見えない（CloudFront の設定を読める人には見える）。
    32 文字未満はデプロイのときに CloudFormation が止める。
    """
    parameter = cdk.CfnParameter(
        stack,
        "OriginVerifyHeaderValue",
        type="String",
        no_echo=True,
        min_length=32,
        description="Secret value that the origin checks to reject requests that bypass this distribution.",
    )
    return parameter.value_as_string


def define_origin_security_group(scope: Construct, configuration: Configuration) -> ec2.SecurityGroup:
    """CloudFront から EC2 の 443 番への接続を許可するセキュリティグループ。インスタンスには手で足す。

    稼働サーバーの今のセキュリティグループは変えない。このグループを「足す」ことで、CloudFront からの接続を許す
    （ステップ 2 の 2-4）。今の 0.0.0.0/0 などの許可を消すのは、ステップ 3 の片付け。
    """
    # 既存の VPC を ID で参照する（AWS を検索しない）。サブネットは本線では使わない（オプションの ALB で使う）
    vpc = ec2.Vpc.from_vpc_attributes(
        scope,
        "Vpc",
        vpc_id=configuration.vpc_id,
        availability_zones=configuration.availability_zones,
        public_subnet_ids=configuration.subnet_ids,
    )
    security_group = ec2.SecurityGroup(
        scope,
        "OriginSecurityGroup",
        vpc=vpc,
        description="HTTPS from CloudFront origin-facing servers. Attach it to the instance.",
    )
    # CloudFront のオリジン向けのアドレスの一覧（AWS が管理するプレフィックスリスト）からだけ、443 番を許可する。
    # このプレフィックスリストはセキュリティグループの規則の上限で 55 件分に数えるので、既存のグループに足さず、
    # 専用のグループにしている
    security_group.add_ingress_rule(
        ec2.Peer.prefix_list(configuration.cloudfront_prefix_list_id),
        ec2.Port.tcp(443),
        "HTTPS from CloudFront",
    )
    return security_group


def define_distribution(
    scope: Construct,
    configuration: Configuration,
    origin_verify_value: str,
    geo_restriction_countries: list[str] | None = None,
) -> cloudfront.Distribution:
    """CloudFront のディストリビューション。キャッシュせず、利用者の Host などをすべてオリジンへ渡す。

    geo_restriction_countries を渡すと、その国からの要求だけを受け付ける（地理的制限）。
    """
    # 地理的制限は既定で使わない（国の絞り込みは WAF で行う。地理的制限で止めた要求は WAF に届かず、
    # Let's Encrypt の確認のパスを例外にできないため）
    geo_restriction = (
        cloudfront.GeoRestriction.allowlist(*geo_restriction_countries) if geo_restriction_countries else None
    )
    # オリジン（稼働サーバー）への接続。CloudFront から稼働サーバーまではインターネットを通るので、HTTPS だけにする。
    # 稼働サーバーの証明書（Let's Encrypt）はオリジンの名前で検証される
    origin = origins.HttpOrigin(
        configuration.origin_domain_name,
        protocol_policy=cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
        origin_ssl_protocols=[cloudfront.OriginSslPolicy.TLS_V1_2],
        read_timeout=cdk.Duration.seconds(configuration.origin_read_timeout_seconds),
        keepalive_timeout=cdk.Duration.seconds(configuration.origin_keepalive_timeout_seconds),
        # CloudFront を通った要求にだけ付く秘密のヘッダー。httpd が確かめて、直接の接続を断る（ステップ 3 の片付け）
        custom_headers={configuration.origin_verify_header_name: origin_verify_value},
    )
    return cloudfront.Distribution(
        scope,
        "Distribution",
        # 利用者のドメイン名をそのまま受ける（代替ドメイン名）。証明書はステップ 1 の us-east-1 の ACM の証明書
        domain_names=[configuration.domain_name],
        certificate=acm.Certificate.from_certificate_arn(
            scope, "CloudFrontCertificate", configuration.cloudfront_certificate_arn
        ),
        minimum_protocol_version=cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
        http_version=cloudfront.HttpVersion.HTTP2,
        # IPv6 を無効にする。ステップ 3 で利用者のドメイン名に作るレコードを A だけにするため
        enable_ipv6=False,
        geo_restriction=geo_restriction,
        # ステップ 2 の WAF の web ACL。空の間は関連付けない（本番では空にしない）
        web_acl_id=configuration.cloudfront_web_acl_arn or None,
        default_behavior=cloudfront.BehaviorOptions(
            origin=origin,
            # 利用者が http で来たら https へリダイレクトする
            viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
            # フォームと API のため、POST・PUT・DELETE なども通す
            allowed_methods=cloudfront.AllowedMethods.ALLOW_ALL,
            cached_methods=cloudfront.CachedMethods.CACHE_GET_HEAD,
            # キャッシュしない（利用者ごとに違う応答を保存しないため）
            cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
            # 利用者の Host（利用者のドメイン名）、Cookie、クエリ文字列、Authorization などをすべてオリジンへ渡す。
            # Host を渡さないと、Rails がリダイレクト先などにオリジンの名前を使ってしまう
            origin_request_policy=cloudfront.OriginRequestPolicy.ALL_VIEWER,
            # CloudFront では圧縮しない（応答はオリジンが返したまま渡す）
            compress=False,
        ),
    )
