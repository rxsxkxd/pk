"""CloudFront → EC2（外部のドメイン名を変えない場合）。"""

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


class CloudFrontToEc2SameDomainStack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "CloudFront -> EC2 with the viewer domain name unchanged. CloudFront terminates viewer TLS and connects "
            "to httpd over HTTPS through a separate origin DNS name, keeping the viewer Host header.",
            configuration,
        )

        if configuration.origin_hosted_zone_id:
            # 利用者のドメイン名のレコードは既にあるので、ここでは作らない。切り替えの時点を担当者が決める
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
        distribution = define_distribution(self, configuration, origin_verify_header_value(self))

        self.output(
            "DistributionDomainName",
            distribution.distribution_domain_name,
            "Point domain_name to this name after checking the distribution.",
        )
        self.output(
            "OriginSecurityGroupId",
            origin_security_group.security_group_id,
            "Attach this security group to the instance before switching DNS.",
        )
