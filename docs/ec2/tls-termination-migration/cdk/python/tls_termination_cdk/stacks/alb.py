"""ALB から EC2 までの部分。ALB → EC2 と CloudFront → ALB → EC2 で共用する。"""

from __future__ import annotations

from dataclasses import dataclass

import aws_cdk as cdk
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_elasticloadbalancingv2 as elbv2
from aws_cdk import aws_elasticloadbalancingv2_targets as targets
from constructs import Construct

from ..configuration import Configuration


@dataclass(frozen=True)
class OriginVerifyHeader:
    """CloudFront が付ける秘密のヘッダー。"""

    name: str
    value: str


class AlbFront(Construct):
    """ALB、ターゲットグループ、リスナー、セキュリティグループ。

    origin_verify を渡すと、CloudFront の後ろに置く形（ヘッダーを見るルールを足す）になる。
    restricted を True にすると、CloudFront 以外からの接続を受けない形になる。
    """

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        configuration: Configuration,
        origin_verify: OriginVerifyHeader | None = None,
        restricted: bool = False,
    ) -> None:
        super().__init__(scope, construct_id)

        vpc = ec2.Vpc.from_vpc_attributes(
            self,
            "Vpc",
            vpc_id=configuration.vpc_id,
            availability_zones=configuration.availability_zones,
            public_subnet_ids=configuration.subnet_ids,
        )
        security_group = self._define_security_group(vpc, configuration, restricted)

        new_app_group = self._define_target_group("NewApp", vpc, configuration, configuration.new_app_port)
        old_app_group = self._define_target_group("OldApp", vpc, configuration, configuration.old_app_port)

        self.load_balancer = elbv2.ApplicationLoadBalancer(
            self,
            "LoadBalancer",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnets=vpc.public_subnets),
            internet_facing=True,
            security_group=security_group,
            idle_timeout=cdk.Duration.seconds(configuration.idle_timeout_seconds),
        )

        if restricted:
            default_action = elbv2.ListenerAction.fixed_response(
                403, content_type="text/plain", message_body="Access denied"
            )
        else:
            default_action = elbv2.ListenerAction.forward([new_app_group])

        https_listener = self.load_balancer.add_listener(
            "Https",
            port=443,
            protocol=elbv2.ApplicationProtocol.HTTPS,
            ssl_policy=elbv2.SslPolicy.RECOMMENDED_TLS,
            certificates=[elbv2.ListenerCertificate.from_arn(configuration.alb_certificate_arn)],
            default_action=default_action,
            open=False,
        )
        self.load_balancer.add_listener(
            "Http",
            port=80,
            protocol=elbv2.ApplicationProtocol.HTTP,
            default_action=elbv2.ListenerAction.redirect(protocol="HTTPS", port="443", permanent=True),
            open=False,
        )

        old_app_path = elbv2.ListenerCondition.path_patterns([configuration.old_app_path_pattern])
        if origin_verify is None:
            https_listener.add_action(
                "OldApp",
                priority=10,
                conditions=[old_app_path],
                action=elbv2.ListenerAction.forward([old_app_group]),
            )
            return

        header = elbv2.ListenerCondition.http_header(origin_verify.name, [origin_verify.value])
        https_listener.add_action(
            "CloudFrontOldApp",
            priority=10,
            conditions=[header, old_app_path],
            action=elbv2.ListenerAction.forward([old_app_group]),
        )
        https_listener.add_action(
            "CloudFrontNewApp",
            priority=20,
            conditions=[header],
            action=elbv2.ListenerAction.forward([new_app_group]),
        )
        if not restricted:
            # 移行の途中で ALB へ直接来ている利用者のために、/old_app_a への経路を残す
            https_listener.add_action(
                "DirectOldApp",
                priority=30,
                conditions=[old_app_path],
                action=elbv2.ListenerAction.forward([old_app_group]),
            )

    def _define_security_group(
        self,
        vpc: ec2.IVpc,
        configuration: Configuration,
        restricted: bool,
    ) -> ec2.SecurityGroup:
        security_group = ec2.SecurityGroup(
            self,
            "SecurityGroup",
            vpc=vpc,
            description="ALB in front of the instance",
            allow_all_outbound=False,
        )
        if restricted:
            security_group.add_ingress_rule(
                ec2.Peer.prefix_list(configuration.cloudfront_prefix_list_id),
                ec2.Port.tcp(443),
                "HTTPS from CloudFront",
            )
        else:
            security_group.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(80), "HTTP from anywhere")
            security_group.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(443), "HTTPS from anywhere")

        instance_security_group = ec2.SecurityGroup.from_security_group_id(
            self,
            "InstanceSecurityGroup",
            configuration.instance_security_group_id,
            mutable=True,
        )
        ports = (configuration.new_app_port, configuration.old_app_port)
        for port in ports:
            instance_security_group.add_ingress_rule(security_group, ec2.Port.tcp(port), f"From the ALB on {port}")

        # add_egress_rule は相手がセキュリティグループだと別のリソース（AWS::EC2::SecurityGroupEgress）になり、
        # 作成時に外向きの規則がないので、既定の全許可が付く。全許可を付けないように、グループの中に直接書く
        cfn_security_group = security_group.node.default_child
        cfn_security_group.security_group_egress = [
            ec2.CfnSecurityGroup.EgressProperty(
                ip_protocol="tcp",
                from_port=port,
                to_port=port,
                destination_security_group_id=configuration.instance_security_group_id,
                description=f"To the instance on {port}",
            )
            for port in ports
        ]
        return security_group

    def _define_target_group(
        self,
        construct_id: str,
        vpc: ec2.IVpc,
        configuration: Configuration,
        port: int,
    ) -> elbv2.ApplicationTargetGroup:
        return elbv2.ApplicationTargetGroup(
            self,
            construct_id,
            vpc=vpc,
            protocol=elbv2.ApplicationProtocol.HTTP,
            port=port,
            target_type=elbv2.TargetType.INSTANCE,
            targets=[targets.InstanceIdTarget(configuration.instance_id, port)],
            health_check=elbv2.HealthCheck(path=configuration.health_check_path, healthy_http_codes="200"),
        )
