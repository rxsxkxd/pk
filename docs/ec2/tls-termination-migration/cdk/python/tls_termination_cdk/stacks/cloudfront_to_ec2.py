"""CloudFront → EC2。"""

from __future__ import annotations

from aws_cdk import aws_ec2 as ec2
from constructs import Construct

from ..configuration import Configuration
from .common import TerminationStack, define_distribution, origin_verify_header_value


class CloudFrontToEc2Stack(TerminationStack):
    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        super().__init__(
            scope,
            stack_name,
            "CloudFront -> EC2. CloudFront terminates viewer TLS and connects to httpd over HTTPS.",
            configuration,
        )

        vpc = ec2.Vpc.from_vpc_attributes(
            self,
            "Vpc",
            vpc_id=configuration.vpc_id,
            availability_zones=configuration.availability_zones,
            public_subnet_ids=configuration.subnet_ids,
        )
        origin_security_group = ec2.SecurityGroup(
            self,
            "OriginSecurityGroup",
            vpc=vpc,
            description="HTTPS from CloudFront origin-facing servers. Attach it to the instance.",
        )
        origin_security_group.add_ingress_rule(
            ec2.Peer.prefix_list(configuration.cloudfront_prefix_list_id),
            ec2.Port.tcp(443),
            "HTTPS from CloudFront",
        )

        distribution = define_distribution(self, configuration, origin_verify_header_value(self))

        self.output("DistributionDomainName", distribution.distribution_domain_name)
        self.output(
            "OriginSecurityGroupId",
            origin_security_group.security_group_id,
            "Attach this security group to the instance before switching DNS.",
        )
