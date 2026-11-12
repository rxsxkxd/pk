"""CDK 版（Python）の 4 つのスタックのテスト。

仕組みの生成ツールのテスト（Go の internal/definitions/definitions_test.go）が守っている約束を、
CDK の assertions（Template.from_stack）で確かめる。AWS には接続しない。

    cd cdk/python && .venv/bin/python -m unittest discover -s tests
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION", "1")

import aws_cdk as cdk  # noqa: E402
from aws_cdk.assertions import Template  # noqa: E402

from ami_publish_cdk.configuration import (  # noqa: E402
    BUILDSPEC_PATH,
    CODEBUILD_IMAGE,
    CONFIG_FILE_ENVIRONMENT_VARIABLE,
    DEFAULT_CONFIG_PATH,
    ConfigurationError,
    load_configuration,
)
from ami_publish_cdk.stacks import define_environment  # noqa: E402

# 生成ツールのテストと同じ設定値（Basic 認証なし、ソースは GitHub）
TEST_CONFIGURATION = """
environments:
  staging:
    aws_region: ap-northeast-1
    application_name: myapp
    release_instance_id: i-0123456789abcdef0
    pipeline:
      source_connection_arn: arn:aws:codeconnections:ap-northeast-1:123456789012:connection/abc
      source_repository_id: example-org/ami-publish
      source_branch_name: main
      log_retention_days: 90
    launch_template:
      instance_type: t3.small
      security_group_ids: [sg-0123456789abcdef0]
    health_check:
      url: http://localhost/up
    timeouts:
      codebuild_minutes: 120
      image_available_seconds: 3600
      instance_online_seconds: 900
      health_check_seconds: 300
      stack_update_seconds: 1800
      poll_interval_seconds: 15
      progress_log_interval_seconds: 60
"""

WITH_BASIC_AUTH = TEST_CONFIGURATION.replace(
    "      url: http://localhost/up\n",
    "      url: http://localhost/up\n      basic_auth_parameter_name: /myapp/staging/health-check/basic-auth\n",
)

WITH_CODECOMMIT = TEST_CONFIGURATION.replace(
    "      source_connection_arn: arn:aws:codeconnections:ap-northeast-1:123456789012:connection/abc\n"
    "      source_repository_id: example-org/ami-publish\n",
    "      source_type: codecommit\n      source_repository_name: ami-publish\n",
)

WITH_TWO_SECURITY_GROUPS = TEST_CONFIGURATION.replace(
    "[sg-0123456789abcdef0]", "[sg-0123456789abcdef0, sg-0fedcba9876543210]"
)

# 合成の結果は設定値ごとに 1 回だけ作る（jsii の呼び出しが遅いため）
_synthesized: dict[str, dict[str, dict]] = {}


def write_configuration(content: str) -> str:
    directory = tempfile.mkdtemp()
    path = Path(directory) / "ami_publish.yml"
    path.write_text(content, encoding="utf-8")
    return str(path)


def synthesize(content: str) -> dict[str, dict]:
    """設定値から 4 つのスタックを合成し、スタック名 → テンプレート（dict）を返す。"""
    if content not in _synthesized:
        app = cdk.App()
        for environment in load_configuration(write_configuration(content)).environments:
            define_environment(app, environment)
        _synthesized[content] = {
            stack.stack_name: Template.from_stack(stack).to_json()
            for stack in app.node.children
            if isinstance(stack, cdk.Stack)
        }
    return _synthesized[content]


def resources_of_type(template: dict, resource_type: str) -> dict[str, dict]:
    return {name: resource for name, resource in template["Resources"].items() if resource["Type"] == resource_type}


def only_resource(template: dict, resource_type: str) -> dict:
    resources = list(resources_of_type(template, resource_type).values())
    assert len(resources) == 1, f"{resource_type} が {len(resources)} 個ある"
    return resources[0]


def policy_statements(template: dict) -> list[dict]:
    """テンプレートの中の IAM の許可（AWS::IAM::Policy と、ロールのインラインのポリシー）をすべて集める。"""
    statements: list[dict] = []
    for resource in template["Resources"].values():
        properties = resource.get("Properties", {})
        if resource["Type"] in ("AWS::IAM::Policy", "AWS::IAM::ManagedPolicy"):
            statements += properties["PolicyDocument"]["Statement"]
        if resource["Type"] == "AWS::IAM::Role":
            for policy in properties.get("Policies", []):
                statements += policy["PolicyDocument"]["Statement"]
    return statements


def actions_of(statement: dict) -> list[str]:
    action = statement["Action"]
    return action if isinstance(action, list) else [action]


def statement_by_sid(template: dict) -> dict[str, dict]:
    return {statement["Sid"]: statement for statement in policy_statements(template) if "Sid" in statement}


def references(value, found: set[str]) -> set[str]:
    """値の中のパラメータ・条件の参照（Ref と Fn::If の条件名）を集める。"""
    if isinstance(value, dict):
        for key, inner in value.items():
            if key == "Ref" and isinstance(inner, str):
                found.add(inner)
            if key == "Fn::If" and isinstance(inner, list) and inner:
                found.add(inner[0])
            references(inner, found)
    elif isinstance(value, list):
        for inner in value:
            references(inner, found)
    return found


class CommonTest(unittest.TestCase):
    def test_four_stacks_with_derived_names(self):
        self.assertEqual(
            sorted(synthesize(TEST_CONFIGURATION)),
            [
                "myapp-staging-ami-publish-pipeline",
                "myapp-staging-health-check",
                "myapp-staging-launch-template",
                "myapp-staging-release-instance",
            ],
        )

    # cdk bootstrap をしていないアカウントにも AWS CLI でデプロイできるように、ブートストラップの確認と
    # CDKMetadata を入れない
    def test_no_bootstrap_rule_or_metadata(self):
        for name, template in synthesize(TEST_CONFIGURATION).items():
            with self.subTest(stack=name):
                self.assertNotIn("Rules", template)
                self.assertNotIn("CDKMetadata", template.get("Resources", {}))
                self.assertNotIn("BootstrapVersion", template.get("Parameters", {}))

    def test_empty_security_groups_are_rejected(self):
        content = TEST_CONFIGURATION.replace("[sg-0123456789abcdef0]", "[]")
        with self.assertRaises(ConfigurationError):
            load_configuration(write_configuration(content))


class LaunchTemplateStackTest(unittest.TestCase):
    def setUp(self):
        self.template = synthesize(TEST_CONFIGURATION)["myapp-staging-launch-template"]
        self.launch_template = only_resource(self.template, "AWS::EC2::LaunchTemplate")
        self.data = self.launch_template["Properties"]["LaunchTemplateData"]

    def test_resources(self):
        for name, resource in self.template["Resources"].items():
            self.assertIn(
                resource["Type"],
                ("AWS::EC2::LaunchTemplate", "AWS::IAM::Role", "AWS::IAM::InstanceProfile"),
                f"起動テンプレートのスタックに想定外のリソース {name} がある",
            )

    # 初回は AmiId を省略でき、そのときは ImageId を入れない（Fn::If と AWS::NoValue）
    def test_image_id_is_optional(self):
        for name in ("AmiId", "AppVersion"):
            self.assertEqual(self.template["Parameters"][name]["Default"], "")
        self.assertIn("HasAmiId", self.template["Conditions"])
        self.assertEqual(
            self.data["ImageId"], {"Fn::If": ["HasAmiId", {"Ref": "AmiId"}, {"Ref": "AWS::NoValue"}]}
        )

    # AMI 公開ツールは、変更セットに起動テンプレートの Modify 以外が含まれたら中止する。
    # パラメータ（と、それに基づく条件）に依存するのは起動テンプレートだけにする
    def test_only_launch_template_depends_on_parameters(self):
        for name, resource in self.template["Resources"].items():
            if resource["Type"] == "AWS::EC2::LaunchTemplate":
                continue
            with self.subTest(resource=name):
                self.assertFalse(references(resource, set()) & {"AmiId", "AppVersion", "HasAmiId"})

    def test_launch_template_data(self):
        self.assertEqual(self.launch_template["Properties"]["LaunchTemplateName"], "myapp-staging")
        self.assertEqual(self.data["MetadataOptions"]["HttpTokens"], "required")
        self.assertEqual(self.data["InstanceType"], "t3.small")
        self.assertEqual(self.data["SecurityGroupIds"], ["sg-0123456789abcdef0"])
        # 後から Auto Scaling グループで使えるよう、サブネットやネットワークインターフェイス、UserData を指定しない
        for key in ("NetworkInterfaces", "SubnetId", "UserData"):
            self.assertNotIn(key, self.data)

    def test_two_security_groups(self):
        template = synthesize(WITH_TWO_SECURITY_GROUPS)["myapp-staging-launch-template"]
        data = only_resource(template, "AWS::EC2::LaunchTemplate")["Properties"]["LaunchTemplateData"]
        self.assertEqual(data["SecurityGroupIds"], ["sg-0123456789abcdef0", "sg-0fedcba9876543210"])

    def test_tags(self):
        for specification in self.data["TagSpecifications"]:
            with self.subTest(resource_type=specification["ResourceType"]):
                keys = [tag["Key"] for tag in specification["Tags"]]
                self.assertEqual(sorted(keys), ["App", "AppVersion"], "L2 が付ける Name タグは付けない")

    # 起動テンプレートのバージョンは Export しない（参照されると更新できなくなる）
    def test_exports(self):
        outputs = self.template["Outputs"]
        self.assertEqual(outputs["StackName"]["Export"]["Name"], "myapp-staging-launch-template:StackName")
        self.assertEqual(
            outputs["LaunchTemplateId"]["Export"]["Name"], "myapp-staging-launch-template:LaunchTemplateId"
        )
        self.assertNotIn("Export", outputs["LaunchTemplateVersion"])


class PipelineStackTest(unittest.TestCase):
    def setUp(self):
        self.template = synthesize(TEST_CONFIGURATION)["myapp-staging-ami-publish-pipeline"]
        self.content = json.dumps(self.template)
        self.pipeline = only_resource(self.template, "AWS::CodePipeline::Pipeline")["Properties"]
        self.project = only_resource(self.template, "AWS::CodeBuild::Project")["Properties"]
        self.statements = statement_by_sid(self.template)

    def test_pipeline(self):
        self.assertEqual(self.pipeline["Name"], "myapp-staging-ami-publish")
        self.assertEqual(self.pipeline["PipelineType"], "V2")
        self.assertEqual(self.pipeline["ExecutionMode"], "QUEUED", "AMI の作成を重ねない")
        self.assertEqual(
            [variable["Name"] for variable in self.pipeline["Variables"]], ["VERSION", "HEALTH_CHECK", "VERIFIED"]
        )

        source, publish = (stage["Actions"][0] for stage in self.pipeline["Stages"])
        self.assertIs(source["Configuration"]["DetectChanges"], False, "push で自動起動しない")
        environment_variables = publish["Configuration"]["EnvironmentVariables"]
        for want in (
            "#{variables.VERSION}",
            "#{variables.VERIFIED}",
            "#{variables.HEALTH_CHECK}",
            "#{codepipeline.PipelineExecutionId}",
        ):
            self.assertIn(want, environment_variables)

    # 設定値ファイルはスタックのパラメータ ConfigFile で指定し、CodeBuild の環境変数 AMI_PUBLISH_CONFIG で渡す
    def test_config_file_parameter(self):
        self.assertEqual(self.template["Parameters"]["ConfigFile"]["Default"], DEFAULT_CONFIG_PATH)
        variables = {
            variable["Name"]: variable["Value"] for variable in self.project["Environment"]["EnvironmentVariables"]
        }
        self.assertEqual(variables[CONFIG_FILE_ENVIRONMENT_VARIABLE], {"Ref": "ConfigFile"})
        self.assertEqual(variables["AMI_PUBLISH_ENVIRONMENT"], "staging")

    def test_codebuild_project(self):
        self.assertEqual(self.project["Name"], "myapp-staging-ami-publish")
        self.assertEqual(self.project["Environment"]["Image"], CODEBUILD_IMAGE)
        self.assertEqual(self.project["TimeoutInMinutes"], 120)
        self.assertEqual(self.project["ConcurrentBuildLimit"], 1)
        self.assertEqual(self.project["Source"]["BuildSpec"], BUILDSPEC_PATH)

    def test_log_group(self):
        log_group = only_resource(self.template, "AWS::Logs::LogGroup")
        self.assertEqual(log_group["Properties"]["LogGroupName"], "/myapp/staging/ami-publish")
        self.assertEqual(log_group["Properties"]["RetentionInDays"], 90)

    # CodeBuild には任意のコマンドを送る AWS-RunShellScript と、インスタンスの停止を許可しない
    def test_forbidden_permissions(self):
        self.assertNotIn("AWS-RunShellScript", self.content)
        self.assertNotIn("ec2:StopInstances", self.content)
        self.assertIn("ec2:StartInstances", self.content)
        # 起動テンプレートのスタックの更新に CloudFormation のサービスロールは使わない。
        # パイプライン全体に IAM ロールを作成・変更する権限を持たせない
        for forbidden in ("cloudformation.amazonaws.com", "iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy"):
            self.assertNotIn(forbidden, self.content)

    # iam:PassRole は、L2 が自動で足す権限を含めて PassReleaseInstanceRole の 1 か所だけ。
    # 対象はリリース用インスタンスのロールだけ、渡す先は EC2 だけ
    def test_pass_role(self):
        pass_role = [
            statement for statement in policy_statements(self.template) if "iam:PassRole" in actions_of(statement)
        ]
        self.assertEqual(len(pass_role), 1)
        self.assertEqual(pass_role[0]["Sid"], "PassReleaseInstanceRole")
        self.assertEqual(pass_role[0]["Action"], "iam:PassRole")
        self.assertEqual(pass_role[0]["Resource"], {"Fn::ImportValue": "myapp-staging-release-instance:RoleArn"})
        self.assertEqual(pass_role[0]["Condition"], {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}})

    def test_release_instance_permissions(self):
        self.assertEqual(
            self.statements["CheckReleaseInstanceRolePermissions"]["Resource"],
            {"Fn::ImportValue": "myapp-staging-release-instance:RoleArn"},
            "ポリシーシミュレーターの対象はリリース用インスタンスのロールだけ",
        )
        self.assertTrue(
            self.statements["AttachReleaseInstanceProfile"]["Resource"]["Fn::Sub"].endswith(
                ":instance/i-0123456789abcdef0"
            ),
            "紐付け・解除の対象はリリース用インスタンスだけ",
        )

    # 起動テンプレートのインスタンスプロファイルを読む。対象は起動テンプレートのスタックが作るものだけ
    def test_read_launch_template_instance_profile(self):
        statement = self.statements["ReadLaunchTemplateInstanceProfile"]
        self.assertEqual(statement["Action"], "iam:GetInstanceProfile")
        body, variables = statement["Resource"]["Fn::Sub"]
        self.assertTrue(body.endswith(":instance-profile/${LaunchTemplateStackName}-*"))
        self.assertEqual(
            variables["LaunchTemplateStackName"], {"Fn::ImportValue": "myapp-staging-launch-template:StackName"}
        )

    # 他のスタックのリソースは、命名規則の文字列ではなく Export で参照する
    def test_references_by_export(self):
        for want in (
            "document/${DocumentName}",
            '{"Fn::ImportValue": "myapp-staging-health-check:DocumentName"}',
            "stack/${LaunchTemplateStackName}/*",
            '{"Fn::ImportValue": "myapp-staging-launch-template:StackName"}',
            "ec2:CreateLaunchTemplateVersion",
            "launch-template/${LaunchTemplateId}",
            '{"Fn::ImportValue": "myapp-staging-launch-template:LaunchTemplateId"}',
        ):
            self.assertIn(want, self.content)
        self.assertNotIn("document/myapp-staging-health-check", self.content)
        self.assertNotIn("stack/myapp-staging-launch-template/", self.content)

    # AMI 公開ツールが他のスタックの名前を引くための出力
    def test_outputs(self):
        for output in (
            "PipelineName",
            "CodeBuildProjectName",
            "ArtifactBucketName",
            "LaunchTemplateStackName",
            "HealthCheckDocumentName",
            "LogGroupName",
            "ReleaseInstanceRoleArn",
            "ReleaseInstanceProfileArn",
        ):
            self.assertIn(output, self.template["Outputs"])

    # 接続の利用は、旧来の接頭辞（codestar-connections）と新しい接頭辞（codeconnections）の両方を許可する
    def test_github_source_connection(self):
        connection_arn = "arn:aws:codeconnections:ap-northeast-1:123456789012:connection/abc"
        allowed = {
            action
            for statement in policy_statements(self.template)
            if statement.get("Resource") == connection_arn
            for action in actions_of(statement)
        }
        self.assertEqual(allowed, {"codestar-connections:UseConnection", "codeconnections:UseConnection"})

    # ソースに CodeCommit を指定した場合は、CodeCommit のソースアクションと、そのリポジトリを取得する権限になる
    def test_codecommit_source(self):
        template = synthesize(WITH_CODECOMMIT)["myapp-staging-ami-publish-pipeline"]
        content = json.dumps(template)
        pipeline = only_resource(template, "AWS::CodePipeline::Pipeline")["Properties"]
        source = pipeline["Stages"][0]["Actions"][0]
        self.assertEqual(source["ActionTypeId"]["Provider"], "CodeCommit")
        self.assertEqual(source["Configuration"]["RepositoryName"], "ami-publish")
        self.assertIs(source["Configuration"]["PollForSourceChanges"], False, "自動起動しない")
        self.assertIn("codecommit:GetBranch", content)
        self.assertNotIn("UseConnection", content, "CodeCommit の場合は CodeConnections の権限を与えない")
        # CodeCommit の自動起動のための EventBridge の規則を作らない
        self.assertFalse(resources_of_type(template, "AWS::Events::Rule"))


class HealthCheckStackTest(unittest.TestCase):
    @staticmethod
    def script(template: dict) -> str:
        properties = template["Resources"]["HealthCheckDocument"]["Properties"]
        return "\n".join(properties["Content"]["mainSteps"][0]["inputs"]["runCommand"]) + "\n"

    def test_without_basic_auth(self):
        template = synthesize(TEST_CONFIGURATION)["myapp-staging-health-check"]
        properties = template["Resources"]["HealthCheckDocument"]["Properties"]
        self.assertEqual(properties["Name"], "myapp-staging-health-check")
        script = self.script(template)
        self.assertIn("curl -sS -o /dev/null -w '%{http_code}' http://localhost/up", script)
        self.assertNotIn("get-parameter", script)
        self.assertNotIn("-K -", script)
        self.assertFalse(resources_of_type(template, "AWS::IAM::ManagedPolicy"))
        self.assertEqual(
            template["Outputs"]["HealthCheckDocumentName"]["Export"]["Name"], "myapp-staging-health-check:DocumentName"
        )

    # Basic 認証の情報は SSM Parameter Store から実行時に取り出し、curl には標準入力（-K -）で渡す
    def test_with_basic_auth(self):
        template = synthesize(WITH_BASIC_AUTH)["myapp-staging-health-check"]
        script = self.script(template)
        for want in (
            "aws ssm get-parameter --region ap-northeast-1 --name '/myapp/staging/health-check/basic-auth'"
            " --with-decryption",
            "basic_auth | curl -K - -sS",
        ):
            self.assertIn(want, script)
        self.assertNotIn(" -u ", script, "認証情報を curl -u で渡さない")

        policy = only_resource(template, "AWS::IAM::ManagedPolicy")
        statement = policy["Properties"]["PolicyDocument"]["Statement"][0]
        self.assertEqual(statement["Action"], "ssm:GetParameter")
        self.assertTrue(statement["Resource"]["Fn::Sub"].endswith(":parameter/myapp/staging/health-check/basic-auth"))
        self.assertIn("BasicAuthParameterReadPolicyArn", template["Outputs"])


class ReleaseInstanceStackTest(unittest.TestCase):
    @staticmethod
    def role(template: dict) -> dict:
        return only_resource(template, "AWS::IAM::Role")["Properties"]

    def test_role_and_instance_profile(self):
        template = synthesize(TEST_CONFIGURATION)["myapp-staging-release-instance"]
        role = self.role(template)
        statement = role["AssumeRolePolicyDocument"]["Statement"][0]
        self.assertEqual(statement["Principal"], {"Service": "ec2.amazonaws.com"})
        self.assertIn(":iam::aws:policy/AmazonSSMManagedInstanceCore", json.dumps(role["ManagedPolicyArns"]))

        statements = role["Policies"][0]["PolicyDocument"]["Statement"]
        self.assertEqual(len(statements), 2, "Basic 認証なしの許可は、ヘルスチェックの出力の書き込みだけ")
        self.assertTrue(statements[0]["Resource"]["Fn::Sub"].endswith(":log-group:/myapp/staging/ami-publish:*"))

        role_name = next(iter(resources_of_type(template, "AWS::IAM::Role")))
        profile = only_resource(template, "AWS::IAM::InstanceProfile")
        self.assertEqual(profile["Properties"]["Roles"], [{"Ref": role_name}])

        outputs = template["Outputs"]
        self.assertEqual(
            outputs["InstanceProfileArn"]["Export"]["Name"], "myapp-staging-release-instance:InstanceProfileArn"
        )
        self.assertEqual(outputs["RoleArn"]["Export"]["Name"], "myapp-staging-release-instance:RoleArn")

    def test_with_basic_auth(self):
        template = synthesize(WITH_BASIC_AUTH)["myapp-staging-release-instance"]
        last = self.role(template)["Policies"][0]["PolicyDocument"]["Statement"][-1]
        self.assertEqual(last["Action"], "ssm:GetParameter")
        self.assertTrue(last["Resource"]["Fn::Sub"].endswith(":parameter/myapp/staging/health-check/basic-auth"))


if __name__ == "__main__":
    unittest.main()
