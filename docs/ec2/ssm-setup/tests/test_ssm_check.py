"""SSM で入れるかの確認のテスト。AWS には接続せず、偽物の AWS CLI で応答を返す。"""

import io
import unittest

from ssm_setup import ssm_check
from ssm_setup.awscli import AwsCliError
from ssm_setup.ssh import SshResult

MARKER = "port-guard-ssm-check-test"
CORE_ARN = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"


def aws_error(code):
    return AwsCliError(["aws"], 254, f"An error occurred ({code}) when calling the Op operation: x")


class FakeAws:
    def __init__(self, instances, associations, profiles, policies, online, session_ok=()):
        self.instances = instances  # インスタンスの ID → 状態
        self.associations = associations  # インスタンスの ID → インスタンスプロファイルの ARN
        self.profiles = profiles  # インスタンスプロファイルの名前 → ロールの名前の一覧
        self.policies = policies  # ロールの名前 → 付いているポリシーの ARN の一覧
        self.online = online  # SSM に Online で登録されているインスタンスの ID
        self.session_ok = set(session_ok)  # Session Manager で echo が返るインスタンスの ID
        self.calls = []
        self.sessions = []

    def available(self):
        return True

    def run(self, *args):
        self.calls.append(args[:2])
        if args[:2] == ("ec2", "describe-instances"):
            instance_id = args[3]
            if instance_id not in self.instances:
                raise aws_error("InvalidInstanceID.NotFound")
            return {"Reservations": [{"Instances": [{"State": {"Name": self.instances[instance_id]},
                                                      "Tags": [{"Key": "Name", "Value": "web"}]}]}]}
        if args[:2] == ("ec2", "describe-iam-instance-profile-associations"):
            arn = self.associations.get(args[3].split("Values=")[1])
            return {"IamInstanceProfileAssociations": [
                {"State": "associated", "IamInstanceProfile": {"Arn": arn}}] if arn else []}
        if args[:2] == ("iam", "get-instance-profile"):
            return {"InstanceProfile": {"Roles": [{"RoleName": r} for r in self.profiles[args[3]]]}}
        if args[:2] == ("iam", "list-attached-role-policies"):
            return {"AttachedPolicies": [{"PolicyArn": a, "PolicyName": a.rsplit("/", 1)[-1]}
                                         for a in self.policies[args[3]]]}
        if args[:2] == ("iam", "list-role-policies"):
            return {"PolicyNames": []}
        if args[:2] == ("ssm", "describe-instance-information"):
            instance_id = args[3].split("Values=")[1]
            if instance_id not in self.online:
                return {"InstanceInformationList": []}
            return {"InstanceInformationList": [{"PingStatus": "Online", "AgentVersion": "3.3.1"}]}
        raise AssertionError(args)

    def run_text(self, *args, timeout=None):
        instance_id = args[args.index("--target") + 1]
        self.sessions.append((instance_id, args[args.index("--document-name") + 1]))
        if instance_id in self.session_ok:
            return 0, f"\nStarting session with SessionId: s-1\n{MARKER}\n\nExiting session with sessionId: s-1.\n", ""
        return 254, "", "An error occurred (AccessDeniedException) when calling the StartSession operation: x"


class FakeRunner:
    def __init__(self, ok):
        self.ok = set(ok)
        self.sent = []

    def run_script(self, instance_id, script, timeout=900):
        self.sent.append(instance_id)
        if instance_id in self.ok:
            return SshResult(0, f"PG ssm_check={MARKER}\n", "", {"ssm_check": MARKER})
        return SshResult(255, "", "SSM のコマンドが届かない（Undeliverable、c-1）")


class RunTest(unittest.TestCase):
    def setUp(self):
        self.aws = FakeAws(
            instances={"i-00000001": "running", "i-00000002": "running", "i-00000003": "running",
                       "i-00000004": "stopped"},
            associations={
                "i-00000001": "arn:aws:iam::1:instance-profile/port-guard-ssm",
                "i-00000002": "arn:aws:iam::1:instance-profile/app/existing",
                "i-00000004": "arn:aws:iam::1:instance-profile/port-guard-ssm",
            },
            profiles={"port-guard-ssm": ["port-guard-ssm"], "existing": ["app-role"]},
            policies={"port-guard-ssm": [CORE_ARN], "app-role": ["arn:aws:iam::1:policy/app-ssm"]},
            online={"i-00000001", "i-00000002"},
            session_ok={"i-00000001", "i-00000002"},
        )
        self.runner = FakeRunner(ok={"i-00000001"})
        self.stdin = io.StringIO("i-00000001\ni-00000002\ni-00000003\ni-00000004\ni-00000009\n")
        self.out = io.StringIO()

    def run_check(self, **kwargs):
        kwargs.setdefault("plugin_available", True)
        return ssm_check.run(self.aws, self.runner, self.stdin, self.out, make_marker=lambda: MARKER, **kwargs)

    def test_session_route(self):
        self.assertEqual(self.run_check(), 1)
        output = self.out.getvalue()
        # Online の 2 台だけ接続を試す（Online でない台・止まっている台・ない台には試さない）
        self.assertEqual(self.aws.sessions, [("i-00000001", "AWS-StartNonInteractiveCommand"),
                                             ("i-00000002", "AWS-StartNonInteractiveCommand")])
        self.assertIn("== 入れる（Online で、Session Manager でつながった。2 台）", output)
        self.assertIn("== 入れない（3 台）", output)
        # 独自のポリシーで入れる台は、付いていないことを知らせるが不合格にはしない
        self.assertIn("AmazonSSMManagedInstanceCore が付いていない（要確認。付いているもの: app-ssm", output)
        self.assertIn("インスタンスプロファイル: existing（ロール: app-role）", output)
        self.assertIn("インスタンスプロファイル: なし", output)
        self.assertIn("SSM の登録が 未登録（Online でない）", output)
        self.assertIn("状態が stopped", output)
        self.assertIn("インスタンスが見つからない", output)
        self.assertIn("結果: 入れる 2 台、入れない 3 台（AmazonSSMManagedInstanceCore が付いていないもの 1 台）", output)
        self.assertEqual(self.runner.sent, [])

    def test_run_command_route(self):
        self.assertEqual(self.run_check(via="run-command"), 1)
        self.assertEqual(self.runner.sent, ["i-00000001", "i-00000002"])
        self.assertEqual(self.aws.sessions, [])
        output = self.out.getvalue()
        self.assertIn("Run Command でつながらない（SSM のコマンドが届かない（Undeliverable、c-1））", output)

    def test_session_failure_is_reported(self):
        self.aws.session_ok = {"i-00000001"}
        self.run_check()
        self.assertIn("Session Manager でつながらない（An error occurred (AccessDeniedException)", self.out.getvalue())

    def test_policy_is_read_once_per_role(self):
        self.stdin = io.StringIO("i-00000001\ni-00000004\n")
        self.run_check()
        self.assertEqual(self.aws.calls.count(("iam", "list-attached-role-policies")), 1)

    def test_all_ok(self):
        self.stdin = io.StringIO("i-00000001\n")
        self.assertEqual(self.run_check(), 0)

    def test_missing_plugin(self):
        self.assertEqual(self.run_check(plugin_available=False), 2)
        self.assertIn("--via run-command", self.out.getvalue())
        self.assertEqual(self.aws.calls, [])


class ProfileNameTest(unittest.TestCase):
    def test_profile_name_with_path(self):
        self.assertEqual(ssm_check.profile_name_of("arn:aws:iam::1:instance-profile/app/existing"), "existing")
        self.assertEqual(ssm_check.profile_name_of(""), "")


if __name__ == "__main__":
    unittest.main()
