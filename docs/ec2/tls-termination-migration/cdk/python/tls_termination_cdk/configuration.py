"""設定値ファイルの読み込み。

検証は、必要な項目があるかだけを確かめる。値の形式は、合成やデプロイのときの検証に任せる。
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml


class ConfigurationError(Exception):
    """設定値ファイルを読めない、または必要な項目がない。"""


REQUIRED_KEYS = (
    "stack_name_prefix",
    "aws_region",
    "vpc_id",
    "availability_zones",
    "subnet_ids",
    "instance_id",
    "instance_security_group_id",
    "cloudfront_prefix_list_id",
    "domain_name",
    "origin_domain_name",
    "alb_certificate_arn",
    "cloudfront_certificate_arn",
)


@dataclass(frozen=True)
class Configuration:
    stack_name_prefix: str
    aws_region: str
    vpc_id: str
    availability_zones: list[str]
    subnet_ids: list[str]
    instance_id: str
    instance_security_group_id: str
    cloudfront_prefix_list_id: str
    domain_name: str
    origin_domain_name: str
    alb_certificate_arn: str
    cloudfront_certificate_arn: str
    alb_web_acl_arn: str = ""
    cloudfront_web_acl_arn: str = ""
    certificate_hosted_zone_id: str = ""
    origin_hosted_zone_id: str = ""
    origin_elastic_ip: str = ""
    restrict_to_cloudfront: bool = False
    new_app_port: int = 8080
    old_app_port: int = 80
    old_app_path_pattern: str = "/old_app_a*"
    health_check_path: str = "/alb-health.txt"
    idle_timeout_seconds: int = 60
    origin_read_timeout_seconds: int = 30
    origin_keepalive_timeout_seconds: int = 5
    origin_verify_header_name: str = "X-Origin-Verify"


def load_configuration(path: str) -> Configuration:
    try:
        values = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ConfigurationError(f"設定値ファイルを読めません: {path}: {error}") from error
    if not isinstance(values, dict):
        raise ConfigurationError(f"設定値ファイルの形が違います: {path}")

    missing = [key for key in REQUIRED_KEYS if not values.get(key)]
    if missing:
        raise ConfigurationError(f"必要な項目がありません: {', '.join(missing)}")

    try:
        configuration = Configuration(**values)
    except TypeError as error:
        raise ConfigurationError(f"未知の項目があります: {error}") from error

    if configuration.origin_domain_name == configuration.domain_name:
        raise ConfigurationError("origin_domain_name は domain_name と別の名前にしてください")
    if configuration.origin_hosted_zone_id and not configuration.origin_elastic_ip:
        raise ConfigurationError("origin_hosted_zone_id を指定するときは origin_elastic_ip も必要です")
    return configuration
