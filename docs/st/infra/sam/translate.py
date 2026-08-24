"""Expands a SAM template into the plain CloudFormation template that sam deploy would create (the
AWS::Serverless-2016-10-31 transform), offline, to compare with infra/cloudformation/api.yaml.

    uvx --with aws-sam-translator==1.113.0 --with pyyaml --with cfn-flip==1.3.0 \
      python translate.py go/template.yaml generated/go.cfn.yaml

The output format follows the extension: .yaml (short-form intrinsics such as !Sub / !Ref, like
infra/cloudformation/api.yaml; uses cfn-flip) or .json. The Lambda code is shown as a placeholder S3 location (sam deploy uploads the built code and fills in the real
bucket and key). Requires no AWS credentials."""

import json
import os
import sys
from pathlib import Path
from typing import Any

from samtranslator.translator.managed_policy_translator import ManagedPolicyLoader
from samtranslator.translator.transform import transform
from samtranslator.yaml_helper import yaml_parse


class NoManagedPolicyLookup(ManagedPolicyLoader):
    """The templates refer to AWS managed policies by ARN only, so no IAM lookup is needed."""

    def __init__(self) -> None:
        pass

    def load(self) -> dict[str, str]:
        return {}


def main(src: str, dst: str) -> None:
    # The transform needs a region for its pseudo parameters; the output still uses ${AWS::Region}.
    os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-1")
    template: dict[str, Any] = yaml_parse(Path(src).read_text())
    for name, resource in template["Resources"].items():
        if resource["Type"] == "AWS::Serverless::Function":
            resource["Properties"]["CodeUri"] = f"s3://ARTIFACT_BUCKET/sam-placeholder/{name}.zip"
    out = transform(template, {}, NoManagedPolicyLookup())
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(out, indent=2, ensure_ascii=False) + "\n"
    if dst.endswith((".yaml", ".yml")):
        from cfn_flip import to_yaml  # only needed for YAML output

        text = to_yaml(text)
    Path(dst).write_text(text)
    print(f"{dst}: {len(out['Resources'])} resources")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
