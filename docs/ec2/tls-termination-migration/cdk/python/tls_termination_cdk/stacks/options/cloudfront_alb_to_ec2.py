"""オプション: CloudFront → ALB → EC2（採用した CloudFront → EC2 ではない構成）。"""

from __future__ import annotations

from constructs import Construct

from ...configuration import Configuration
from ..common import TerminationStack, define_distribution, origin_verify_header_value
from .alb import AlbFront, OriginVerifyHeader


class CloudFrontAlbToEc2Stack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "CloudFront -> ALB -> EC2. CloudFront terminates viewer TLS, connects to the ALB over HTTPS, "
            "and the ALB forwards HTTP to httpd on the existing instance.",
            configuration,
        )

        verify_value = origin_verify_header_value(self)
        front = AlbFront(
            self,
            "AlbFront",
            configuration,
            origin_verify=OriginVerifyHeader(configuration.origin_verify_header_name, verify_value),
            restricted=configuration.restrict_to_cloudfront,
        )
        distribution = define_distribution(self, configuration, verify_value)

        self.output("DistributionDomainName", distribution.distribution_domain_name)
        self.output(
            "LoadBalancerDnsName",
            front.load_balancer.load_balancer_dns_name,
            "Point origin_domain_name to this name.",
        )
        self.output("LoadBalancerCanonicalHostedZoneId", front.load_balancer.load_balancer_canonical_hosted_zone_id)
