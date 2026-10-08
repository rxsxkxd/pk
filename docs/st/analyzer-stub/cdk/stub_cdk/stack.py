"""The VPC stub on ECS Fargate (test only): the container image (built from ../{node,python,rust}/Dockerfile
and pushed by cdk deploy), the cluster and task definition, the task's security group (unless given) and,
optionally, VPC endpoints for ECR / S3 / CloudWatch Logs. The VPC and subnet come from settings (made
beforehand by ../network.yaml or existing). No ECS service: tasks are started and stopped by hand
(aws ecs run-task / stop-task), so nothing runs, and nothing is billed, between checks. See ../DESIGN.md 付録 B."""

from pathlib import Path

from aws_cdk import Aws, CfnOutput, RemovalPolicy, Stack
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_ecr_assets as ecr_assets
from aws_cdk import aws_ecs as ecs
from aws_cdk import aws_logs as logs
from constructs import Construct

from stub_cdk.settings import StubSettings

STUB_ROOT = Path(__file__).resolve().parents[2]  # analyzer-stub/
STUB_PORT = 8090


class StubFargateStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, *, settings: StubSettings, **kwargs: object) -> None:
        super().__init__(scope, construct_id, **kwargs)  # type: ignore[arg-type]
        s = settings

        # The image is built here (arm64, like the task) and pushed to the CDK bootstrap repository on deploy.
        image = ecr_assets.DockerImageAsset(
            self,
            "Image",
            directory=str(STUB_ROOT / s.impl),
            platform=ecr_assets.Platform.LINUX_ARM64,
        )
        log_group = logs.LogGroup(
            self,
            "LogGroup",
            log_group_name=f"/ecs/ticketqr-analyzer-stub-{s.impl}",
            retention=logs.RetentionDays.ONE_WEEK,
            removal_policy=RemovalPolicy.DESTROY,
        )

        # L1: the L2 Cluster would create a VPC of its own when none is given.
        cluster = ecs.CfnCluster(self, "Cluster", cluster_name=f"ticketqr-analyzer-stub-{s.impl}")

        task_definition = ecs.FargateTaskDefinition(
            self,
            "TaskDefinition",
            family=f"ticketqr-analyzer-stub-{s.impl}",
            cpu=256,
            memory_limit_mib=512,
            runtime_platform=ecs.RuntimePlatform(
                cpu_architecture=ecs.CpuArchitecture.ARM64,
                operating_system_family=ecs.OperatingSystemFamily.LINUX,
            ),
        )
        task_definition.add_container(
            "stub",
            image=ecs.ContainerImage.from_docker_image_asset(image),
            essential=True,
            readonly_root_filesystem=True,
            port_mappings=[ecs.PortMapping(container_port=STUB_PORT)],
            # Reachable only from the tickets function's security group, so no API key (../DESIGN.md 3.3).
            environment={"STUB_AUTH": "none", "PORT": str(STUB_PORT)},
            logging=ecs.LogDrivers.aws_logs(stream_prefix="stub", log_group=log_group),
        )

        task_security_group_id = s.task_security_group_id or self._task_security_group(s)
        if s.create_endpoints:
            self._endpoints(s, task_security_group_id, image, log_group)

        CfnOutput(self, "ClusterName", value=cluster.ref)
        CfnOutput(self, "TaskDefinitionFamily", value=f"ticketqr-analyzer-stub-{s.impl}")
        CfnOutput(self, "SubnetId", value=s.subnet_id)
        CfnOutput(self, "TaskSecurityGroupId", value=task_security_group_id)
        CfnOutput(self, "ImageUri", value=image.image_uri)
        CfnOutput(self, "LogGroupName", value=log_group.log_group_name)

    def _task_security_group(self, s: StubSettings) -> str:
        """タスクの SG を作る（network.yaml の SG を使わないとき）。受信は指定した SG からの 8090、送信は 443 だけ。"""
        group = ec2.CfnSecurityGroup(
            self,
            "TaskSecurityGroup",
            group_description=f"ticketqr analyzer stub ({s.impl}) task",
            vpc_id=s.vpc_id,
            security_group_ingress=[
                ec2.CfnSecurityGroup.IngressProperty(
                    ip_protocol="tcp",
                    from_port=STUB_PORT,
                    to_port=STUB_PORT,
                    source_security_group_id=s.allowed_source_security_group_id,
                    description="the ticket API (tickets function)",
                )
            ],
            # Replaces the default allow-all egress. Replies to the API need no rule (stateful).
            security_group_egress=[
                ec2.CfnSecurityGroup.EgressProperty(
                    ip_protocol="tcp", from_port=443, to_port=443, cidr_ip="0.0.0.0/0", description="ECR, S3 and CloudWatch Logs"
                )
            ],
        )
        return group.attr_group_id

    def _endpoints(
        self, s: StubSettings, task_security_group_id: str, image: ecr_assets.DockerImageAsset, log_group: logs.LogGroup
    ) -> None:
        """VPC エンドポイント（ecr.api・ecr.dkr・logs と S3 のゲートウェイ型）。ポリシーで、このイメージの取得と
        このロググループへの書き込みだけを許す。ポリシーとプライベート DNS は VPC 全体に効くので、スタブだけが使う
        VPC に限る。"""
        endpoint_group = ec2.CfnSecurityGroup(
            self,
            "EndpointSecurityGroup",
            group_description=f"ticketqr analyzer stub ({s.impl}) VPC endpoints",
            vpc_id=s.vpc_id,
            security_group_ingress=[
                ec2.CfnSecurityGroup.IngressProperty(
                    ip_protocol="tcp",
                    from_port=443,
                    to_port=443,
                    source_security_group_id=task_security_group_id,
                    description="the stub task",
                )
            ],
        )
        ecr_policy = {
            "Version": "2012-10-17",
            "Statement": [
                {"Effect": "Allow", "Principal": "*", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
                {
                    "Effect": "Allow",
                    "Principal": "*",
                    "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
                    "Resource": image.repository.repository_arn,
                },
            ],
        }
        logs_policy = {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": "*",
                    "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
                    "Resource": log_group.log_group_arn,
                }
            ],
        }
        for construct_id, service, policy in [
            ("EcrApiEndpoint", "ecr.api", ecr_policy),
            ("EcrDkrEndpoint", "ecr.dkr", ecr_policy),
            ("LogsEndpoint", "logs", logs_policy),
        ]:
            ec2.CfnVPCEndpoint(
                self,
                construct_id,
                vpc_endpoint_type="Interface",
                service_name=f"com.amazonaws.{Aws.REGION}.{service}",
                vpc_id=s.vpc_id,
                subnet_ids=[s.subnet_id],
                security_group_ids=[endpoint_group.attr_group_id],
                private_dns_enabled=True,
                policy_document=policy,
            )
        # ECR keeps image layers in an AWS-owned S3 bucket per region.
        ec2.CfnVPCEndpoint(
            self,
            "S3GatewayEndpoint",
            vpc_endpoint_type="Gateway",
            service_name=f"com.amazonaws.{Aws.REGION}.s3",
            vpc_id=s.vpc_id,
            route_table_ids=[s.route_table_id or ""],
            policy_document={
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Principal": "*",
                        "Action": "s3:GetObject",
                        "Resource": f"arn:{Aws.PARTITION}:s3:::prod-{Aws.REGION}-starport-layer-bucket/*",
                    }
                ],
            },
        )
