"""CloudFormation 版との照合。AWS には接続しない。"""

import copy
import json
from pathlib import Path
import tempfile
import unittest

import aws_cdk as cdk
import yaml

from list_refresh_stack import ListRefreshPipelineStack


def normalize(value):
    """同じ意味の GetAtt の書き方をそろえる。ほかのテンプレートの内容は変えない。"""
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {
            key: item.split(".", 1) if key == "Fn::GetAtt" and isinstance(item, str) else normalize(item)
            for key, item in value.items()
        }
    return value


class ListRefreshPipelineStackTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.output.cleanup)
        app = cdk.App(outdir=cls.output.name)
        stack = ListRefreshPipelineStack(app, "port-guard-list-refresh-test")
        cls.template = app.synth().get_stack_by_name(stack.stack_name).template

    def test_matches_cloudformation_definition(self):
        source = Path(__file__).resolve().parents[3] / "cloudformation/list-refresh-pipeline.yml"
        expected = yaml.safe_load(source.read_text(encoding="utf-8"))
        actual = copy.deepcopy(self.template)
        for template in (expected, actual):
            # 説明文と形式の宣言は CDK 版と異なる。リソースの設定はすべて照合する。
            template.pop("Description", None)
            template.pop("AWSTemplateFormatVersion", None)
            for resource in template["Resources"].values():
                if resource["Type"] == "AWS::CodeBuild::Project":
                    source_properties = resource["Properties"]["Source"]
                    source_properties["BuildSpec"] = yaml.safe_load(source_properties["BuildSpec"])
        self.maxDiff = None
        self.assertEqual(normalize(expected), normalize(actual))

    def test_can_deploy_template_directly_without_bootstrap_parameters(self):
        # AWS CLI で直接渡せる大きさを守り、CDK のブートストラップへの依存を増やさない。
        self.assertLess(len(json.dumps(self.template).encode("utf-8")), 51_200)
        self.assertEqual(
            set(self.template["Parameters"]),
            {"EnvironmentName", "PublishBucketName", "PublishKeyPrefix", "RequireApproval", "LogRetentionInDays"},
        )
        self.assertNotIn("Rules", self.template)


if __name__ == "__main__":
    unittest.main()
