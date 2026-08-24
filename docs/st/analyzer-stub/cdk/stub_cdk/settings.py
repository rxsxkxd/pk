"""Deploy-time settings of the VPC stub, from CDK context (-c key=value). The VPC and the subnet are made
beforehand: the public subnet of ../network.yaml (recommended for tests), or a private subnet of an existing
VPC. See ../../DEPLOY.md 3.4."""

import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal

type Impl = Literal["node", "python", "rust"]
IMPLS: tuple[Impl, ...] = ("node", "python", "rust")


@dataclass(frozen=True)
class StubSettings:
    impl: Impl
    vpc_id: str
    subnet_id: str
    # The task's security group made elsewhere (TaskSecurityGroupId output of network.yaml). None: this stack
    # makes one that admits allowed_source_security_group_id.
    task_security_group_id: str | None
    allowed_source_security_group_id: str | None
    # True: make VPC endpoints for ECR / S3 / CloudWatch Logs (only in a VPC used by the stub alone).
    create_endpoints: bool
    route_table_id: str | None  # of subnet_id; needed by the S3 gateway endpoint when create_endpoints

    @property
    def stack_name(self) -> str:
        return f"ticketqr-analyzer-stub-vpc-{self.impl}"


def settings_from_context(get: Callable[[str], object]) -> StubSettings:
    """CDK のコンテキスト（cdk deploy -c key=value）から設定を読み、足りない・形が違うものはエラーにする。"""

    def text(key: str) -> str | None:
        value = get(key)
        if value is None:
            return None
        return str(value).strip() or None

    def required(key: str, pattern: str) -> str:
        value = text(key)
        if value is None:
            raise ValueError(f"context {key} is required (cdk deploy -c {key}=...)")
        return matching(key, value, pattern)

    def optional(key: str, pattern: str) -> str | None:
        value = text(key)
        return None if value is None else matching(key, value, pattern)

    impl = text("impl") or "node"
    if impl not in IMPLS:
        raise ValueError(f"context impl must be one of {', '.join(IMPLS)}, got {impl!r}")
    create_endpoints = (text("createEndpoints") or "false").lower()
    if create_endpoints not in ("true", "false"):
        raise ValueError(f"context createEndpoints must be true or false, got {create_endpoints!r}")

    settings = StubSettings(
        impl=impl,  # narrowed to Impl by the check against IMPLS above
        vpc_id=required("vpcId", r"vpc-[0-9a-f]+"),
        subnet_id=required("subnetId", r"subnet-[0-9a-f]+"),
        task_security_group_id=optional("taskSecurityGroupId", r"sg-[0-9a-f]+"),
        allowed_source_security_group_id=optional("allowedSourceSecurityGroupId", r"sg-[0-9a-f]+"),
        create_endpoints=create_endpoints == "true",
        route_table_id=optional("routeTableId", r"rtb-[0-9a-f]+"),
    )
    if settings.task_security_group_id is None and settings.allowed_source_security_group_id is None:
        raise ValueError("context allowedSourceSecurityGroupId is required when taskSecurityGroupId is not given")
    if settings.create_endpoints and settings.route_table_id is None:
        raise ValueError("context routeTableId is required when createEndpoints=true")
    return settings


def matching(key: str, value: str, pattern: str) -> str:
    if not re.fullmatch(pattern, value):
        raise ValueError(f"context {key} must match {pattern}, got {value!r}")
    return value
