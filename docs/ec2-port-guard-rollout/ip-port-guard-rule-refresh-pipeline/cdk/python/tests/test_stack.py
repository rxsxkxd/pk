"""2 種類の定義の動作・権限・スタック分離を、AWS に接続せずに確かめる。"""

import json
from pathlib import Path
import re
import tempfile
import unittest

import aws_cdk as cdk
import yaml

from list_refresh_stack import ListRefreshPipelineStack
from rule_buckets_stack import RuleBucketsStack

ROOT = Path(__file__).resolve().parents[3]


class CfnLoader(yaml.SafeLoader):
    pass


def intrinsic(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    else:
        value = loader.construct_sequence(node)
    if tag == "GetAtt" and isinstance(value, str):
        value = value.split(".", 1)
    return {"Ref" if tag == "Ref" else f"Fn::{tag}": value}


CfnLoader.add_multi_constructor("!", intrinsic)


def load_template(name):
    return yaml.load((ROOT / "cloudformation" / name).read_text(), Loader=CfnLoader)


def evaluate(template, supplied=None):
    """比較に必要な組み込み関数と条件を、同じ具体値で評価する。"""
    parameters = {k: v.get("Default") for k, v in template.get("Parameters", {}).items()}
    parameters.update({"AWS::AccountId": "111122223333", "AWS::Region": "ap-northeast-1",
                       "AWS::Partition": "aws", "AWS::NoValue": None})
    parameters.update(supplied or {})

    def resolve(value):
        if isinstance(value, list):
            return [v for x in value if (v := resolve(x)) is not None]
        if not isinstance(value, dict):
            return value
        if "Ref" in value:
            key = value["Ref"]
            if key in parameters:
                return parameters[key]
            resource = template["Resources"][key]
            props = resource["Properties"]
            if resource["Type"] == "AWS::S3::Bucket":
                return resolve(props["BucketNamePrefix"]) + "-111122223333-ap-northeast-1-an"
            return resolve(props.get("Name", props.get("LogGroupName", key)))
        if "Fn::Equals" in value:
            a, b = value["Fn::Equals"]
            return resolve(a) == resolve(b)
        if "Fn::If" in value:
            condition, yes, no = value["Fn::If"]
            return resolve(yes if resolve(template["Conditions"][condition]) else no)
        if "Fn::Sub" in value:
            data = value["Fn::Sub"]
            text, mapping = (data, {}) if isinstance(data, str) else data
            return re.sub(r"\$\{([^}]+)\}", lambda m: str(resolve(mapping.get(m[1], {"Ref": m[1]}))), text)
        if "Fn::Join" in value:
            separator, parts = value["Fn::Join"]
            return separator.join(str(resolve(x)) for x in parts)
        if "Fn::Split" in value:
            separator, text = value["Fn::Split"]
            return resolve(text).split(separator)
        if "Fn::Select" in value:
            index, items = value["Fn::Select"]
            return resolve(items)[int(index)]
        if "Fn::GetAtt" in value:
            resource, attribute = value["Fn::GetAtt"]
            return f"{resource}.{attribute}"
        return {k: resolve(v) for k, v in value.items()}

    resources = {k: resolve(v) for k, v in template["Resources"].items()
                 if not v.get("Condition") or resolve(template["Conditions"][v["Condition"]])}
    return resources, resolve(template["Outputs"])


def of_type(resources, kind):
    return {k: v for k, v in resources.items() if v["Type"] == kind}


class StacksTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.output.cleanup)
        app = cdk.App(outdir=cls.output.name)
        buckets = RuleBucketsStack(app, "test-buckets")
        pipeline = ListRefreshPipelineStack(app, "test-pipeline")
        assembly = app.synth()
        cls.cdk_buckets = assembly.get_stack_by_name(buckets.stack_name).template
        cls.cdk_pipeline = assembly.get_stack_by_name(pipeline.stack_name).template
        cls.yaml_buckets = load_template("rule-buckets.yml")
        cls.yaml_pipeline = load_template("list-refresh-pipeline.yml")
        cls.pipeline_parameters = {
            "EnvironmentName": "staging", "PipelineBucketName": "artifact-bucket",
            "PublishBucketName": "rule-bucket", "ConnectionArn": "arn:aws:codeconnections:ap-northeast-1:111122223333:connection/example",
            "FullRepositoryId": "owner/group/repository", "SourceDirectory": "nested/project",
        }

    def test_stack_ownership_and_existing_bucket(self):
        for template in (self.yaml_pipeline, self.cdk_pipeline):
            self.assertFalse(of_type(template["Resources"], "AWS::S3::Bucket"))
        for template in (self.yaml_buckets, self.cdk_buckets):
            self.assertEqual({r["Type"] for r in template["Resources"].values()}, {"AWS::S3::Bucket"})
            resources, outputs = evaluate(template)
            self.assertEqual(len(resources), 1)
            self.assertEqual(outputs["PublishBucketName"]["Value"],
                             "ip-port-guard-rules-111122223333-ap-northeast-1-an")
            _, outputs = evaluate(template, {"PublishBucketName": "already-created"})
            self.assertEqual(outputs["PublishBucketName"]["Value"], "already-created")
            resources, _ = evaluate(template, {"CreatePublishBucket": "true"})
            self.assertEqual(len(resources), 2)
            for resource in resources.values():
                self.assertEqual(resource["DeletionPolicy"], "Retain")
                self.assertEqual(resource["UpdateReplacePolicy"], "Retain")
                properties = resource["Properties"]
                self.assertTrue(all(properties["PublicAccessBlockConfiguration"].values()))
                self.assertEqual(properties["BucketNamespace"], "account-regional")
                self.assertEqual(properties["VersioningConfiguration"]["Status"], "Enabled")
                self.assertEqual(properties["BucketEncryption"]["ServerSideEncryptionConfiguration"][0]
                                 ["ServerSideEncryptionByDefault"]["SSEAlgorithm"], "AES256")

    def test_pipeline_flow_and_buildspecs_match(self):
        for approval in ("true", "false"):
            observed = []
            for template in (self.yaml_pipeline, self.cdk_pipeline):
                resources, _ = evaluate(template, self.pipeline_parameters | {"RequireApproval": approval})
                flow = next(iter(of_type(resources, "AWS::CodePipeline::Pipeline").values()))["Properties"]
                self.assertEqual(flow["ExecutionMode"], "QUEUED")
                self.assertEqual(flow["PipelineType"], "V2")
                stages = flow["Stages"]
                self.assertEqual([s["Name"] for s in stages],
                                 ["Source", "Make", "Check", "Publish"] if approval == "true" else ["Source", "Make", "Publish"])
                source = stages[0]["Actions"][0]["Configuration"]
                self.assertIn(source["DetectChanges"], (False, "false"))
                self.assertEqual(source["FullRepositoryId"], "owner/group/repository")
                self.assertEqual(stages[-1]["Actions"][0]["InputArtifacts"], [{"Name": "MadeFiles"}])
                force = json.loads(stages[1]["Actions"][0]["Configuration"]["EnvironmentVariables"])
                self.assertEqual(force[0]["value"], "#{variables.FORCE}")
                projects = {}
                for resource in of_type(resources, "AWS::CodeBuild::Project").values():
                    props = resource["Properties"]
                    projects[props["Name"]] = (yaml.safe_load(props["Source"]["BuildSpec"]),
                        {v["Name"]: v["Value"] for v in props["Environment"]["EnvironmentVariables"]})
                observed.append(projects)
            self.assertEqual(*observed)

    def test_rule_bucket_permissions_are_separated(self):
        for template in (self.yaml_pipeline, self.cdk_pipeline):
            resources, _ = evaluate(template, self.pipeline_parameters)
            policies = []
            for key, resource in resources.items():
                props = resource["Properties"]
                if resource["Type"] == "AWS::IAM::Policy":
                    policies.append((key, props["PolicyDocument"]["Statement"]))
                if resource["Type"] == "AWS::IAM::Role":
                    policies.extend((key, p["PolicyDocument"]["Statement"]) for p in props.get("Policies", []))
            for role, statements in policies:
                rule_statements = [s for s in statements if "rule-bucket" in json.dumps(s.get("Resource"))]
                if "Make" in role:
                    self.assertEqual({a for s in rule_statements for a in self.as_list(s["Action"])},
                                     {"s3:GetObject", "s3:ListBucket"})
                    listing = next(s for s in rule_statements if s["Action"] == "s3:ListBucket")
                    self.assertEqual(listing["Condition"]["StringLike"]["s3:prefix"], "port-guard/staging/current/*")
                elif "Publish" in role:
                    self.assertEqual(len(rule_statements), 1)
                    self.assertEqual(rule_statements[0]["Action"], "s3:PutObject")
                    self.assertEqual(rule_statements[0]["Resource"], "arn:aws:s3:::rule-bucket/port-guard/staging/current/*")
                else:
                    self.assertEqual(rule_statements, [])

    @staticmethod
    def as_list(value):
        return value if isinstance(value, list) else [value]

    def test_direct_templates_have_no_bootstrap_or_assets(self):
        for template in (self.cdk_buckets, self.cdk_pipeline):
            self.assertLess(len(json.dumps(template).encode()), 51_200)
            self.assertNotIn("BootstrapVersion", template.get("Parameters", {}))
            self.assertFalse(any(r["Type"].startswith("Custom::") for r in template["Resources"].values()))
        self.assertEqual(set(self.yaml_pipeline["Parameters"]), set(self.cdk_pipeline["Parameters"]))
        self.assertEqual(set(self.yaml_buckets["Parameters"]), set(self.cdk_buckets["Parameters"]))


if __name__ == "__main__":
    unittest.main()
