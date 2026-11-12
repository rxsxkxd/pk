"""オプション: ALB → EC2（採用した CloudFront → EC2 ではない構成）。"""

from __future__ import annotations

from aws_cdk import aws_wafv2 as wafv2
from constructs import Construct

from ...configuration import Configuration
from ..common import TerminationStack
from .alb import AlbFront


class AlbToEc2Stack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "ALB -> EC2. ALB terminates TLS and forwards HTTP to httpd on the existing instance.",
            configuration,
        )

        front = AlbFront(self, "AlbFront", configuration)

        if configuration.alb_web_acl_arn:
            wafv2.CfnWebACLAssociation(
                self,
                "AlbWebAclAssociation",
                resource_arn=front.load_balancer.load_balancer_arn,
                web_acl_arn=configuration.alb_web_acl_arn,
            )

        self.output("LoadBalancerDnsName", front.load_balancer.load_balancer_dns_name)
        self.output("LoadBalancerCanonicalHostedZoneId", front.load_balancer.load_balancer_canonical_hosted_zone_id)
