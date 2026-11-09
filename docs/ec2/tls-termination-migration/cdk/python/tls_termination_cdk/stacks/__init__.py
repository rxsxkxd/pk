"""3 つの構成のスタックの定義。"""

from __future__ import annotations

from constructs import Construct

from ..configuration import Configuration
from .alb_to_ec2 import AlbToEc2Stack
from .cloudfront_alb_to_ec2 import CloudFrontAlbToEc2Stack
from .cloudfront_to_ec2 import CloudFrontToEc2Stack


def define_stacks(scope: Construct, configuration: Configuration) -> None:
    prefix = configuration.stack_name_prefix
    AlbToEc2Stack(scope, f"{prefix}-alb-to-ec2", configuration)
    CloudFrontToEc2Stack(scope, f"{prefix}-cloudfront-to-ec2", configuration)
    CloudFrontAlbToEc2Stack(scope, f"{prefix}-cloudfront-alb-to-ec2", configuration)
