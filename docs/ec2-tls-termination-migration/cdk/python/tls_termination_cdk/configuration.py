"""設定値ファイルの読み込み。

設定値ファイル（YAML）を読み、Configuration にして返す。合成（app.py）の最初に 1 回だけ呼ぶ。

検証は、必要な項目があるかと、取り違えると危ない組み合わせだけを確かめる。値の形式（ARN や CIDR の書き方）は、
合成やデプロイのときの検証（CloudFormation）に任せる。
必要な項目は 2 段に分ける。CloudFront → EC2 の 3 ステップ（本線）に要る項目と、
option_stacks で指定したオプションの構成（ALB を使う構成）にだけ要る項目。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml


class ConfigurationError(Exception):
    """設定値ファイルを読めない、または必要な項目がない。app.py が受けて、終了コード 2 で止める。"""


# CloudFront → EC2 の 3 ステップに要る項目。ステップ 1 だけを CDK で行うときも、合成はすべての本線のスタックを
# 定義するので、ここにある項目は全部書く
REQUIRED_KEYS = (
    "stack_name_prefix",
    "aws_region",
    "vpc_id",
    "availability_zones",
    "cloudfront_prefix_list_id",
    "domain_name",
    "origin_domain_name",
)

# オプションの構成の名前（option_stacks に書く値）と、その構成にだけ要る項目。
# 名前は stacks/__init__.py の OPTION_STACKS と同じにする
ALB_KEYS = ("subnet_ids", "instance_id", "instance_security_group_id", "alb_certificate_arn")
OPTION_REQUIRED_KEYS: dict[str, tuple[str, ...]] = {
    "alb-to-ec2": ALB_KEYS,
    "cloudfront-alb-to-ec2": (*ALB_KEYS, "cloudfront_certificate_arn"),
}


@dataclass(frozen=True)
class Configuration:
    """設定値。項目の名前は設定値ファイルのキーと同じ。

    既定値のない項目は REQUIRED_KEYS と同じで、必ず書く。既定値のある項目は省略できる。
    設定値ファイルに、ここにない項目を書くとエラーにする（綴りの誤りを見つけるため）。
    frozen にして、スタックの定義の途中で値を書き換えられないようにしている。
    """

    # ---- どのステップでも要る ----
    # スタック名の頭（例 myapp-production）。スタック名は <prefix>-step1-certificate のように決まる
    stack_name_prefix: str
    # ステップ 2 の CloudFront のスタックを置くリージョン（ステップ 1 と WAF はいつも us-east-1）
    aws_region: str
    # 稼働サーバーの VPC と AZ。オリジン用のセキュリティグループを作るのに使う（VPC は ID で参照するだけで、AWS を検索しない）
    vpc_id: str
    availability_zones: list[str]
    # com.amazonaws.global.cloudfront.origin-facing のプレフィックスリストの ID（リージョンごとに違う）
    cloudfront_prefix_list_id: str
    # 利用者のドメイン名（例 app.example.com）。CloudFront の代替ドメイン名と、証明書の名前になる
    domain_name: str
    # オリジンの名前（例 origin.app.example.com）。CloudFront が稼働サーバーへ接続するときの名前
    origin_domain_name: str

    # ステップ 1 の出力 CertificateArn。空の間は、ステップ 2 の CloudFront のスタックを定義しない
    cloudfront_certificate_arn: str = ""
    # ステップ 2 の WAF のスタックの出力 WebAclArn。空なら関連付けない（本番では空にしない）
    cloudfront_web_acl_arn: str = ""
    # ステップ 1: domain_name の Route 53 のホストゾーン。指定すると ACM の検証用のレコードを自動で作る
    certificate_hosted_zone_id: str = ""
    # ステップ 2: origin_domain_name の A レコードも作るときに、2 つとも指定する
    origin_hosted_zone_id: str = ""
    origin_elastic_ip: str = ""
    # CloudFront の地理的制限で許可する国（ISO 3166-1 alpha-2）。既定は空で、制限しない。
    # 国の絞り込みは WAF（waf_allowed_countries）で行う。地理的制限で止めた要求は WAF に届かないので、
    # 地理的制限を使うと、EC2 の Let's Encrypt の証明書を HTTP-01 で更新できなくなる
    geo_restriction_countries: list[str] = field(default_factory=list)
    # ステップ 2 の WAF の web ACL（<prefix>-step2-waf）で許可する国
    waf_allowed_countries: list[str] = field(default_factory=lambda: ["JP"])
    # 許可する国の外から通す IP（CIDR）。空のままでよい
    waf_exception_ipv4_addresses: list[str] = field(default_factory=list)
    waf_exception_ipv6_addresses: list[str] = field(default_factory=list)
    # CloudFront がオリジンの応答を待つ秒数。アプリの最長の応答に合わせる
    origin_read_timeout_seconds: int = 30
    # CloudFront がオリジンとの接続を使い回す秒数。httpd の KeepAliveTimeout をこれより長くする
    origin_keepalive_timeout_seconds: int = 5
    # 秘密のヘッダーの名前。値は設定値ファイルに書かず、デプロイのときのパラメータで渡す
    origin_verify_header_name: str = "X-Origin-Verify"

    # ---- ここから下は、オプションの構成（ALB を使う構成）でだけ使う ----
    # 合成するオプションの構成の名前（alb-to-ec2、cloudfront-alb-to-ec2）。空なら合成しない
    option_stacks: list[str] = field(default_factory=list)
    # ALB を置くパブリックサブネット（availability_zones と同じ順番で、AZ ごとに 1 つ）
    subnet_ids: list[str] = field(default_factory=list)
    # ALB のターゲットにする稼働サーバー
    instance_id: str = ""
    # 稼働サーバーの既存のセキュリティグループ。ALB からの許可を足す
    instance_security_group_id: str = ""
    # ALB のリスナーの証明書（ALB と同じリージョンの ACM）
    alb_certificate_arn: str = ""
    # ALB に関連付ける WAF の web ACL（リージョンの web ACL）。空なら関連付けない
    alb_web_acl_arn: str = ""
    # cloudfront-alb-to-ec2 だけで使う。true にすると CloudFront 以外からの接続を受けない
    restrict_to_cloudfront: bool = False
    # 稼働サーバーの httpd のポート。新しいアプリと、/old_app_a のアプリ
    new_app_port: int = 8080
    old_app_port: int = 80
    old_app_path_pattern: str = "/old_app_a*"
    # ALB のヘルスチェックのパス（httpd が 200 を返すファイル）
    health_check_path: str = "/alb-health.txt"
    idle_timeout_seconds: int = 60


def load_configuration(path: str) -> Configuration:
    """設定値ファイルを読み、検証して返す。誤りがあれば ConfigurationError を投げる。"""
    try:
        values = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ConfigurationError(f"設定値ファイルを読めません: {path}: {error}") from error
    if not isinstance(values, dict):
        raise ConfigurationError(f"設定値ファイルの形が違います: {path}")

    # 必須の項目。空の文字列や空の一覧も「ない」と扱う
    missing = [key for key in REQUIRED_KEYS if not values.get(key)]
    if missing:
        raise ConfigurationError(f"必要な項目がありません: {', '.join(missing)}")

    # Configuration にない項目があると TypeError になるので、未知の項目として知らせる
    try:
        configuration = Configuration(**values)
    except TypeError as error:
        raise ConfigurationError(f"未知の項目があります: {error}") from error

    # オプションの構成は、書いた構成に要る項目だけを確かめる
    for option in configuration.option_stacks:
        if option not in OPTION_REQUIRED_KEYS:
            known = ", ".join(OPTION_REQUIRED_KEYS)
            raise ConfigurationError(f"option_stacks に未知の構成があります: {option}（使えるのは {known}）")
        missing = [key for key in OPTION_REQUIRED_KEYS[option] if not values.get(key)]
        if missing:
            raise ConfigurationError(f"option_stacks の {option} に必要な項目がありません: {', '.join(missing)}")

    # オリジンの名前を利用者のドメイン名と同じにすると、ステップ 3 の後に CloudFront が自分自身へ接続してしまう
    if configuration.origin_domain_name == configuration.domain_name:
        raise ConfigurationError("origin_domain_name は domain_name と別の名前にしてください")
    # オリジンの名前の A レコードを作るには、向け先の Elastic IP が要る
    if configuration.origin_hosted_zone_id and not configuration.origin_elastic_ip:
        raise ConfigurationError("origin_hosted_zone_id を指定するときは origin_elastic_ip も必要です")
    # 許可する国が空だと、確認のパスと例外の IP 以外がすべて止まる
    if not configuration.waf_allowed_countries:
        raise ConfigurationError("waf_allowed_countries に許可する国を 1 つ以上書いてください")
    return configuration
