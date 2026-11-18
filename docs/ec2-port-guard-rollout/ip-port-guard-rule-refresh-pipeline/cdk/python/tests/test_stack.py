"""YAML 版と CDK 版のパイプライン用スタックの動作・権限・バケットを、AWS に接続せずに確かめる。"""

import json
from pathlib import Path
import re
import tempfile
import unittest

import aws_cdk as cdk
import yaml

from list_refresh_stack import ListRefreshPipelineStack
from rule_deploy_bucket_stack import RuleDeployBucketStack

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
        if "Fn::Not" in value:
            return not resolve(value["Fn::Not"][0])
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
        pipelines = {provider: ListRefreshPipelineStack(app, f"test-pipeline-{provider.lower()}", provider)
                     for provider in ("GitHub", "CodeCommit")}
        bucket_stack = RuleDeployBucketStack(app, "test-rule-deploy-bucket")
        assembly = app.synth()
        cls.cdk_rule_deploy_bucket = assembly.get_stack_by_name(bucket_stack.stack_name).template
        # CDK 版はリポジトリのホストを合成時に選ぶので、ホストごとにテンプレートがある
        cls.cdk_pipelines = {provider: assembly.get_stack_by_name(stack.stack_name).template
                             for provider, stack in pipelines.items()}
        cls.cdk_pipeline = cls.cdk_pipelines["GitHub"]
        cls.yaml_pipeline = load_template("list-refresh-pipeline.yml")
        common = {"EnvironmentName": "staging", "RuleDeployBucketNamePrefix": "rule-bucket",
                  "SourceDirectory": "nested/project"}
        # YAML 版はリポジトリのホストをデプロイ時のパラメータ SourceProvider で選ぶ
        cls.source_parameters = {
            "GitHub": common | {"SourceProvider": "GitHub", "FullRepositoryId": "owner/group/repository",
                                "ConnectionArn": "arn:aws:codeconnections:ap-northeast-1:111122223333:connection/example"},
            "CodeCommit": common | {"SourceProvider": "CodeCommit", "CodeCommitRepositoryName": "rule-generator"},
        }
        cls.pipeline_parameters = cls.source_parameters["GitHub"]

    def test_pipeline_stack_owns_only_the_handoff_bucket(self):
        for template in (self.yaml_pipeline, *self.cdk_pipelines.values()):
            resources, outputs = evaluate(template, self.pipeline_parameters)
            buckets = of_type(resources, "AWS::S3::Bucket")
            # パイプラインの受け渡しバケットだけを作り、ルールのデプロイ先バケットは作らない
            self.assertEqual(len(buckets), 1)
            bucket = next(iter(buckets.values()))
            self.assertEqual(bucket["DeletionPolicy"], "Retain")
            self.assertEqual(bucket["UpdateReplacePolicy"], "Retain")
            properties = bucket["Properties"]
            self.assertEqual(properties["BucketNamePrefix"], "port-guard-handoff-staging")
            self.assertTrue(all(properties["PublicAccessBlockConfiguration"].values()))
            self.assertEqual(properties["BucketNamespace"], "account-regional")
            self.assertEqual(properties["VersioningConfiguration"]["Status"], "Enabled")
            self.assertEqual(properties["BucketEncryption"]["ServerSideEncryptionConfiguration"][0]
                             ["ServerSideEncryptionByDefault"]["SSEAlgorithm"], "AES256")
            flow = next(iter(of_type(resources, "AWS::CodePipeline::Pipeline").values()))["Properties"]
            handoff = "port-guard-handoff-staging-111122223333-ap-northeast-1-an"
            self.assertEqual(flow["ArtifactStore"]["Location"], handoff)
            self.assertEqual(outputs["PipelineHandoffBucketName"]["Value"], handoff)
            self.assertEqual(outputs["RuleDeployLocation"]["Value"],
                             "s3://rule-bucket-111122223333-ap-northeast-1-an/port-guard/staging/current")

    def test_bucket_names_fit_in_63_characters(self):
        # アカウントのリージョナル名前空間では、後ろに付く -<アカウント ID>-<リージョン>-an も 63 文字に数える
        suffix = "-111122223333-ap-northeast-1-an"
        for environment in ("development", "staging", "production"):
            for template in (self.yaml_pipeline, *self.cdk_pipelines.values()):
                resources, _ = evaluate(template, self.pipeline_parameters | {"EnvironmentName": environment})
                for bucket in of_type(resources, "AWS::S3::Bucket").values():
                    self.assertLessEqual(len(bucket["Properties"]["BucketNamePrefix"] + suffix), 63)
        rule_prefix = load_template("rule-deploy-bucket.yml")["Parameters"]["RuleDeployBucketNamePrefix"]["Default"]
        self.assertLessEqual(len(rule_prefix + suffix), 63)

    def test_rule_deploy_bucket_yaml_and_cdk_match(self):
        yaml_resources, yaml_outputs = evaluate(load_template("rule-deploy-bucket.yml"))
        cdk_resources, cdk_outputs = evaluate(self.cdk_rule_deploy_bucket)
        self.assertEqual(set(yaml_resources), {"RuleDeployBucket"})
        self.assertEqual(set(cdk_resources), {"RuleDeployBucket"})
        for key in ("DeletionPolicy", "UpdateReplacePolicy"):
            self.assertEqual(yaml_resources["RuleDeployBucket"][key], cdk_resources["RuleDeployBucket"][key])
        self.assertEqual(yaml_resources["RuleDeployBucket"]["Properties"], cdk_resources["RuleDeployBucket"]["Properties"])
        self.assertEqual(yaml_outputs["RuleDeployBucketName"]["Value"], cdk_outputs["RuleDeployBucketName"]["Value"])
        self.assertEqual(set(load_template("rule-deploy-bucket.yml")["Parameters"]), set(self.cdk_rule_deploy_bucket["Parameters"]))

    def test_rule_deploy_bucket_record_matches_pipeline(self):
        # 作り方の記録のテンプレートが作るバケットの名前を、パイプライン用スタックが参照する名前と合わせる
        template = load_template("rule-deploy-bucket.yml")
        resources, outputs = evaluate(template)
        self.assertEqual(list(resources), ["RuleDeployBucket"])
        bucket = resources["RuleDeployBucket"]
        self.assertEqual(bucket["DeletionPolicy"], "Retain")
        properties = bucket["Properties"]
        self.assertEqual(properties["BucketNamespace"], "account-regional")
        self.assertTrue(all(properties["PublicAccessBlockConfiguration"].values()))
        self.assertEqual(properties["VersioningConfiguration"]["Status"], "Enabled")
        self.assertNotIn("LifecycleConfiguration", properties)
        default = self.yaml_pipeline["Parameters"]["RuleDeployBucketNamePrefix"]["Default"]
        self.assertEqual(template["Parameters"]["RuleDeployBucketNamePrefix"]["Default"], default)
        _, pipeline_outputs = evaluate(self.yaml_pipeline, self.pipeline_parameters | {"RuleDeployBucketNamePrefix": default})
        self.assertEqual(pipeline_outputs["RuleDeployLocation"]["Value"],
                         f"s3://{outputs['RuleDeployBucketName']['Value']}/port-guard/staging/current")

    def test_pipeline_flow_and_buildspecs_match(self):
        for provider, approval in [(p, a) for p in ("GitHub", "CodeCommit") for a in ("true", "false")]:
            observed = []
            for template in (self.yaml_pipeline, self.cdk_pipelines[provider]):
                resources, _ = evaluate(template, self.source_parameters[provider] | {"RequireApproval": approval})
                flow = next(iter(of_type(resources, "AWS::CodePipeline::Pipeline").values()))["Properties"]
                self.assertEqual(flow["ExecutionMode"], "QUEUED")
                self.assertEqual(flow["PipelineType"], "V2")
                stages = flow["Stages"]
                self.assertEqual([s["Name"] for s in stages],
                                 ["Source", "Make", "Check", "Publish"] if approval == "true" else ["Source", "Make", "Publish"])
                action = stages[0]["Actions"][0]
                source = action["Configuration"]
                self.assertEqual(action["OutputArtifacts"], [{"Name": "SourceFiles"}])
                self.assertEqual(source["OutputArtifactFormat"], "CODE_ZIP")
                self.assertEqual(source["BranchName"], "main")
                if provider == "GitHub":
                    self.assertEqual(action["ActionTypeId"]["Provider"], "CodeStarSourceConnection")
                    self.assertIn(source["DetectChanges"], (False, "false"))
                    self.assertEqual(source["FullRepositoryId"], "owner/group/repository")
                else:
                    self.assertEqual(action["ActionTypeId"]["Provider"], "CodeCommit")
                    self.assertIn(source["PollForSourceChanges"], (False, "false"))
                    self.assertEqual(source["RepositoryName"], "rule-generator")
                    # ソースの変更では自動で開始しないので、変更を拾う EventBridge の規則は作らない（あるのは定期実行の規則だけ）
                    self.assertFalse([r for r in of_type(resources, "AWS::Events::Rule").values()
                                      if "EventPattern" in r["Properties"]])
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

    @staticmethod
    def policies(resources):
        found = []
        for key, resource in resources.items():
            props = resource["Properties"]
            if resource["Type"] == "AWS::IAM::Policy":
                found.append((key, props["PolicyDocument"]["Statement"]))
            if resource["Type"] == "AWS::IAM::Role":
                found.extend((key, p["PolicyDocument"]["Statement"]) for p in props.get("Policies", []))
        return found

    def test_source_permissions_follow_provider(self):
        for provider in ("GitHub", "CodeCommit"):
            for template in (self.yaml_pipeline, self.cdk_pipelines[provider]):
                resources, _ = evaluate(template, self.source_parameters[provider])
                statements = [s for _, found in self.policies(resources) for s in found]
                actions = {a for s in statements for a in self.as_list(s["Action"])}
                connection = [s for s in statements if "codestar-connections:UseConnection" in self.as_list(s["Action"])]
                repository = [s for s in statements if any(a.startswith("codecommit:") for a in self.as_list(s["Action"]))]
                if provider == "GitHub":
                    self.assertTrue(connection)
                    self.assertTrue(all(s["Resource"] == self.source_parameters["GitHub"]["ConnectionArn"] for s in connection))
                    self.assertFalse(repository)
                else:
                    self.assertFalse(connection)
                    self.assertTrue({"codecommit:GetBranch", "codecommit:GetCommit", "codecommit:UploadArchive",
                                     "codecommit:GetUploadArchiveStatus", "codecommit:CancelUploadArchive"} <= actions)
                    for s in repository:
                        self.assertEqual(s["Resource"], "arn:aws:codecommit:ap-northeast-1:111122223333:rule-generator")

    def test_schedule_starts_only_this_pipeline(self):
        for provider in ("GitHub", "CodeCommit"):
            for template in (self.yaml_pipeline, self.cdk_pipelines[provider]):
                parameters = self.source_parameters[provider]
                # 既定は毎週月曜・木曜の UTC 0:00
                resources, _ = evaluate(template, parameters)
                rules = list(of_type(resources, "AWS::Events::Rule").values())
                self.assertEqual(len(rules), 1)
                rule = rules[0]["Properties"]
                self.assertEqual(rule["ScheduleExpression"], "cron(0 0 ? * MON,THU *)")
                self.assertEqual(rule["State"], "ENABLED")
                pipeline_arn = "arn:aws:codepipeline:ap-northeast-1:111122223333:port-guard-list-refresh-staging"
                self.assertEqual([t["Arn"] for t in rule["Targets"]], [pipeline_arn])
                schedule_statements = [s for key, found in self.policies(resources) if "Schedule" in key for s in found]
                self.assertEqual([(s["Action"], s["Resource"]) for s in schedule_statements],
                                 [("codepipeline:StartPipelineExecution", pipeline_arn)])
                # 空なら定期実行の規則もロールも作らない
                resources, _ = evaluate(template, parameters | {"ScheduleExpression": ""})
                self.assertFalse(of_type(resources, "AWS::Events::Rule"))
                self.assertFalse([k for k in resources if "Schedule" in k])

    def test_notification_only_when_topic_is_given(self):
        topic = "arn:aws:sns:ap-northeast-1:111122223333:port-guard-alerts"
        for provider in ("GitHub", "CodeCommit"):
            for template in (self.yaml_pipeline, self.cdk_pipelines[provider]):
                for given in ("", topic):
                    resources, _ = evaluate(template, self.source_parameters[provider] | {"NotificationTopicArn": given})
                    publishers = {("Make" if "Make" in key else key) for key, found in self.policies(resources)
                                  for s in found if "sns:Publish" in self.as_list(s["Action"])}
                    variables = {}
                    for project in of_type(resources, "AWS::CodeBuild::Project").values():
                        props = project["Properties"]
                        variables[props["Name"]] = {v["Name"]: v["Value"] for v in props["Environment"]["EnvironmentVariables"]}
                    make = variables["port-guard-list-refresh-staging-make"]
                    if given:
                        # Make のロールだけが、そのトピックへ送れる
                        self.assertEqual(publishers, {"Make"})
                        for key, found in self.policies(resources):
                            for s in found:
                                if "sns:Publish" in self.as_list(s["Action"]):
                                    self.assertEqual(s["Resource"], topic)
                        self.assertEqual(make["NOTIFICATION_TOPIC_ARN"], topic)
                    else:
                        self.assertEqual(publishers, set())
                        self.assertNotIn("NOTIFICATION_TOPIC_ARN", make)
                    self.assertNotIn("NOTIFICATION_TOPIC_ARN", variables["port-guard-list-refresh-staging-publish"])

    def test_rule_bucket_permissions_are_separated(self):
        for provider in ("GitHub", "CodeCommit"):
            for template in (self.yaml_pipeline, self.cdk_pipelines[provider]):
                resources, _ = evaluate(template, self.source_parameters[provider])
                self.check_rule_bucket_permissions(self.policies(resources))

    def check_rule_bucket_permissions(self, policies):
        # CDK 版は 1 つのロールの権限が複数のポリシーに分かれるので、ロールの種類（Make・Publish・ほか）ごとにまとめて見る
        grouped = {}
        for key, statements in policies:
            role = "Make" if "Make" in key else "Publish" if "Publish" in key else key
            grouped.setdefault(role, []).extend(statements)
        for role, statements in grouped.items():
            rule_statements = [s for s in statements if "rule-bucket" in json.dumps(s.get("Resource"))]
            if role == "Make":
                self.assertEqual({a for s in rule_statements for a in self.as_list(s["Action"])},
                                 {"s3:GetObject", "s3:ListBucket"})
                listing = next(s for s in rule_statements if s["Action"] == "s3:ListBucket")
                self.assertEqual(listing["Condition"]["StringLike"]["s3:prefix"], "port-guard/staging/current/*")
            elif "Publish" in role:
                self.assertEqual(len(rule_statements), 1)
                self.assertEqual(rule_statements[0]["Action"], "s3:PutObject")
                self.assertEqual(rule_statements[0]["Resource"], "arn:aws:s3:::rule-bucket-111122223333-ap-northeast-1-an/port-guard/staging/current/*")
            else:
                self.assertEqual(rule_statements, [])

    @staticmethod
    def as_list(value):
        return value if isinstance(value, list) else [value]

    def test_direct_templates_have_no_bootstrap_or_assets(self):
        for template in self.cdk_pipelines.values():
            self.assertLess(len(json.dumps(template).encode()), 51_200)
            self.assertNotIn("BootstrapVersion", template.get("Parameters", {}))
            self.assertFalse(any(r["Type"].startswith("Custom::") for r in template["Resources"].values()))
        # YAML 版のパラメータ = CDK 版の両方のホストのパラメータ ＋ ホストを選ぶ SourceProvider
        yaml_parameters = set(self.yaml_pipeline["Parameters"])
        github, codecommit = (set(t["Parameters"]) for t in (self.cdk_pipelines["GitHub"], self.cdk_pipelines["CodeCommit"]))
        self.assertEqual(yaml_parameters, github | codecommit | {"SourceProvider"})
        self.assertEqual(github - codecommit, {"ConnectionArn", "FullRepositoryId"})
        self.assertEqual(codecommit - github, {"CodeCommitRepositoryName"})


if __name__ == "__main__":
    unittest.main()
