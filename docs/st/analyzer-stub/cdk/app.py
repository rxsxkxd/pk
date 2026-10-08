"""CDK app of the VPC stub (ECS Fargate). Settings come from context, e.g.

    npx aws-cdk@2.1145.0 deploy -c impl=node -c vpcId=vpc-... -c subnetId=subnet-... -c taskSecurityGroupId=sg-...

See ../../DEPLOY.md 3.4 and ../DESIGN.md 付録 B."""

import aws_cdk as cdk

from stub_cdk.settings import settings_from_context
from stub_cdk.stack import StubFargateStack

app = cdk.App()
settings = settings_from_context(app.node.try_get_context)
StubFargateStack(
    app,
    settings.stack_name,
    settings=settings,
    description="Image analysis server stub on ECS Fargate (test only). See docs/st/DEPLOY.md 3.4.",
)
app.synth()
