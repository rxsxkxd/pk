"""The synthesized template, without AWS or Docker. Run: .venv/bin/python -m unittest -v"""

import unittest
from typing import Any

import aws_cdk as cdk
from aws_cdk.assertions import Match, Template

from stub_cdk.settings import settings_from_context
from stub_cdk.stack import StubFargateStack

PUBLIC = {  # network.yaml's public subnet and security group
    "impl": "node",
    "vpcId": "vpc-0123456789abcdef0",
    "subnetId": "subnet-0123456789abcdef0",
    "taskSecurityGroupId": "sg-0123456789abcdef0",
}
PRIVATE_ENDPOINTS = {  # a stub-only VPC's private subnet, endpoints made here, security group made here
    "impl": "rust",
    "vpcId": "vpc-0123456789abcdef0",
    "subnetId": "subnet-0123456789abcdef0",
    "routeTableId": "rtb-0123456789abcdef0",
    "createEndpoints": "true",
    "allowedSourceSecurityGroupId": "sg-0fedcba9876543210",
}


def synth(context: dict[str, Any]) -> Template:
    app = cdk.App()
    settings = settings_from_context(context.get)
    return Template.from_stack(StubFargateStack(app, settings.stack_name, settings=settings))


class PublicSubnet(unittest.TestCase):
    def setUp(self) -> None:
        self.template = synth(PUBLIC)

    def test_task_definition_is_arm64_with_no_api_key_and_a_read_only_root(self) -> None:
        self.template.has_resource_properties(
            "AWS::ECS::TaskDefinition",
            {
                "Family": "ticketqr-analyzer-stub-node",
                "Cpu": "256",
                "Memory": "512",
                "RequiresCompatibilities": ["FARGATE"],
                "NetworkMode": "awsvpc",
                "RuntimePlatform": {"CpuArchitecture": "ARM64", "OperatingSystemFamily": "LINUX"},
                "ContainerDefinitions": [
                    Match.object_like(
                        {
                            "Name": "stub",
                            "ReadonlyRootFilesystem": True,
                            "PortMappings": [Match.object_like({"ContainerPort": 8090})],
                            "Environment": Match.array_with(
                                [{"Name": "STUB_AUTH", "Value": "none"}, {"Name": "PORT", "Value": "8090"}]
                            ),
                        }
                    )
                ],
            },
        )

    def test_uses_the_given_security_group_and_makes_no_network_resources(self) -> None:
        self.template.resource_count_is("AWS::EC2::SecurityGroup", 0)
        self.template.resource_count_is("AWS::EC2::VPCEndpoint", 0)
        self.template.resource_count_is("AWS::EC2::VPC", 0)
        self.template.has_output("TaskSecurityGroupId", {"Value": "sg-0123456789abcdef0"})

    def test_cluster_and_log_group(self) -> None:
        self.template.has_resource_properties("AWS::ECS::Cluster", {"ClusterName": "ticketqr-analyzer-stub-node"})
        self.template.has_resource_properties(
            "AWS::Logs::LogGroup", {"LogGroupName": "/ecs/ticketqr-analyzer-stub-node", "RetentionInDays": 7}
        )


class PrivateSubnetWithEndpoints(unittest.TestCase):
    def setUp(self) -> None:
        self.template = synth(PRIVATE_ENDPOINTS)

    def test_task_security_group_admits_only_the_tickets_group_and_sends_only_https(self) -> None:
        self.template.has_resource_properties(
            "AWS::EC2::SecurityGroup",
            {
                "GroupDescription": "ticketqr analyzer stub (rust) task",
                "SecurityGroupIngress": [
                    Match.object_like(
                        {"IpProtocol": "tcp", "FromPort": 8090, "ToPort": 8090, "SourceSecurityGroupId": "sg-0fedcba9876543210"}
                    )
                ],
                "SecurityGroupEgress": [
                    Match.object_like({"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "CidrIp": "0.0.0.0/0"})
                ],
            },
        )

    def test_endpoints_for_ecr_logs_and_s3(self) -> None:
        self.template.resource_count_is("AWS::EC2::VPCEndpoint", 4)
        self.template.has_resource_properties(
            "AWS::EC2::VPCEndpoint",
            {"VpcEndpointType": "Gateway", "RouteTableIds": ["rtb-0123456789abcdef0"]},
        )
        self.template.has_resource_properties(
            "AWS::EC2::VPCEndpoint",
            {"VpcEndpointType": "Interface", "PrivateDnsEnabled": True, "SubnetIds": ["subnet-0123456789abcdef0"]},
        )


class Settings(unittest.TestCase):
    def test_required_and_conditional_values(self) -> None:
        cases: list[tuple[dict[str, object], str]] = [
            ({**PUBLIC, "vpcId": None}, "vpcId is required"),
            ({**PUBLIC, "subnetId": "sub-1"}, "subnetId must match"),
            ({**PUBLIC, "impl": "go"}, "impl must be one of"),
            ({**PUBLIC, "taskSecurityGroupId": None}, "allowedSourceSecurityGroupId is required"),
            ({**PUBLIC, "createEndpoints": "true"}, "routeTableId is required"),
            ({**PUBLIC, "createEndpoints": "yes"}, "createEndpoints must be true or false"),
        ]
        for context, message in cases:
            with self.subTest(message), self.assertRaisesRegex(ValueError, message):
                settings_from_context(context.get)


if __name__ == "__main__":
    unittest.main()
