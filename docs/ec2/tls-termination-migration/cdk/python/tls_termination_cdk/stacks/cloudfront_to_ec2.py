"""CloudFront → EC2。"""

from __future__ import annotations

from constructs import Construct

from ..configuration import Configuration
from .common import (
    TerminationStack,
    define_distribution,
    define_origin_security_group,
    origin_verify_header_value,
)


class CloudFrontToEc2Stack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "CloudFront -> EC2. CloudFront terminates viewer TLS and connects to httpd over HTTPS.",
            configuration,
        )

        origin_security_group = define_origin_security_group(self, configuration)
        distribution = define_distribution(
            self, configuration, origin_verify_header_value(self), configuration.geo_restriction_countries
        )

        self.output("DistributionDomainName", distribution.distribution_domain_name)
        self.output(
            "OriginSecurityGroupId",
            origin_security_group.security_group_id,
            "Attach this security group to the instance before switching DNS.",
        )
