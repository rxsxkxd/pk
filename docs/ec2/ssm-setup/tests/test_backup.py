"""バックアップのテスト。AWS には接続せず、AWS CLI の代わりの偽物で応答を返す。

    python3 -m unittest discover -s tests
"""

import io
import json
import unittest
from datetime import datetime

from ssm_setup import backup
from ssm_setup.awscli import AwsCliError
from ssm_setup.targets import read_targets


def instance(instance_id, name="web", state="running", root="ebs"):
    return {"Reservations": [{"Instances": [{
        "InstanceId": instance_id,
        "State": {"Name": state},
        "InstanceType": "t3a.medium",
        "Placement": {"AvailabilityZone": "ap-northeast-1a"},
        "RootDeviceType": root,
        "BlockDeviceMappings": [{"DeviceName": "/dev/xvda"}],
        "Tags": [{"Key": "Name", "Value": name}],
    }]}]}


def aws_error(code, message="error"):
    return AwsCliError(["aws"], 254, f"An error occurred ({code}) when calling the Op operation: {message}")


class FakeAws:
    """インスタンスの ID ごとに、describe-instances と create-image（試行と本番）の応答を決めておく。"""

    def __init__(self, instances=None, dry_run=None, create=None):
        self.instances = instances or {}
        self.dry_run = dry_run or {}
        self.create = create or {}
        self.calls = []

    def available(self):
        return True

    def run(self, *args):
        self.calls.append(args)
        instance_id = args[args.index("--instance-ids" if "--instance-ids" in args else "--instance-id") + 1]
        if args[1] == "describe-instances":
            value = self.instances.get(instance_id, aws_error("InvalidInstanceID.NotFound"))
        elif "--dry-run" in args:
            value = self.dry_run.get(instance_id, aws_error("DryRunOperation"))
        else:
            value = self.create.get(instance_id, {"ImageId": "ami-" + instance_id[2:]})
        if isinstance(value, Exception):
            raise value
        return value


class ReadTargetsTest(unittest.TestCase):
    def test_skips_blank_comments_duplicates_and_reports_invalid(self):
        stdin = io.StringIO("i-0123456789abcdef0\n\n# comment\ni-0123456789abcdef0\n"
                            "i-abcdef12 localhost:2222  # tail\nfoo\ni-abcdef13 a b\n")
        targets, invalid = read_targets(stdin)
        self.assertEqual([(t.instance_id, t.ssh_target) for t in targets],
                         [("i-0123456789abcdef0", ""), ("i-abcdef12", "localhost:2222")])
        self.assertEqual(invalid, ["foo", "i-abcdef13 a b"])


class InspectTest(unittest.TestCase):
    def test_classifies_instances(self):
        aws = FakeAws(
            instances={
                "i-00000001": instance("i-00000001"),
                "i-00000002": instance("i-00000002", state="stopped"),
                "i-00000003": instance("i-00000003", state="terminated"),
                "i-00000004": instance("i-00000004", root="instance-store"),
                "i-00000005": instance("i-00000005"),
            },
            dry_run={"i-00000005": aws_error("UnauthorizedOperation")},
        )
        results = {i: backup.inspect(aws, i) for i in
                   ["i-00000001", "i-00000002", "i-00000003", "i-00000004", "i-00000005", "i-00000009"]}
        self.assertTrue(results["i-00000001"].backupable)
        self.assertTrue(results["i-00000002"].backupable)
        self.assertIn("状態が terminated", results["i-00000003"].reasons[0])
        self.assertIn("EBS ではない", results["i-00000004"].reasons[0])
        self.assertIn("権限がない", results["i-00000005"].reasons[0])
        self.assertIn("見つからない", results["i-00000009"].reasons[0])


class ImageNameTest(unittest.TestCase):
    def test_replaces_disallowed_characters_and_limits_length(self):
        candidate = backup.Candidate("i-0123456789abcdef0", name="本番 web:01" + "x" * 200)
        name = backup.image_name(candidate, "20261029-101500")
        self.assertLessEqual(len(name), backup.AMI_NAME_MAX_LENGTH)
        self.assertTrue(name.endswith("i-0123456789abcdef0-before-ssm-setup-20261029-101500"))
        self.assertNotIn(":", name)
        self.assertNotIn(" ", name)

    def test_does_not_start_with_hyphen(self):
        candidate = backup.Candidate("i-0123456789abcdef0", name="物件A web")
        self.assertEqual(backup.image_name(candidate, "20261029-101500"),
                         "A-web-i-0123456789abcdef0-before-ssm-setup-20261029-101500")
        candidate = backup.Candidate("i-0123456789abcdef0", name="本番")
        self.assertEqual(backup.image_name(candidate, "20261029-101500"),
                         "i-0123456789abcdef0-before-ssm-setup-20261029-101500")


class RunTest(unittest.TestCase):
    def setUp(self):
        self.aws = FakeAws(
            instances={"i-00000001": instance("i-00000001"), "i-00000002": instance("i-00000002")},
            create={"i-00000002": aws_error("InvalidParameterValue", "bad")},
        )
        self.stdin = io.StringIO("i-00000001\ni-00000002\ni-00000009\n")
        self.out = io.StringIO()
        self.now = datetime(2026, 10, 29, 10, 15, 0)

    def creates(self):
        return [c for c in self.aws.calls if c[1] == "create-image" and "--dry-run" not in c]

    def test_creates_images_serially_after_confirmation(self):
        code = backup.run(self.aws, self.stdin, self.out, "2026-10", confirm_func=lambda q: True, now=self.now)
        self.assertEqual(code, 1)  # 1 台は対象外、1 台は失敗
        creates = self.creates()
        self.assertEqual([c[c.index("--instance-id") + 1] for c in creates], ["i-00000001", "i-00000002"])
        self.assertIn("--no-reboot", creates[0])
        tag_arg = next(a for a in creates[0] if a.startswith("--tag-specifications="))
        tags = json.loads(tag_arg.split("=", 1)[1])
        self.assertEqual({t["ResourceType"] for t in tags}, {"image", "snapshot"})
        self.assertIn({"Key": "BackupLabel", "Value": "2026-10"}, tags[0]["Tags"])
        output = self.out.getvalue()
        self.assertIn("開始  i-00000001 → ami-00000001", output)
        self.assertIn("失敗  i-00000002", output)
        self.assertIn("見つからない", output)

    def test_rejects_bad_label(self):
        self.assertEqual(backup.run(self.aws, self.stdin, self.out, "本番 10 月", confirm_func=lambda q: True), 2)
        self.assertEqual(self.creates(), [])

    def test_stops_when_declined(self):
        code = backup.run(self.aws, self.stdin, self.out, "2026-10", confirm_func=lambda q: False)
        self.assertEqual(code, 0)
        self.assertEqual(self.creates(), [])
        self.assertIn("中止した", self.out.getvalue())

    def test_requires_terminal_or_yes(self):
        code = backup.run(self.aws, self.stdin, self.out, "2026-10", confirm_func=lambda q: None)
        self.assertEqual(code, 2)
        self.assertEqual(self.creates(), [])

    def test_check_only_does_not_create(self):
        code = backup.run(self.aws, self.stdin, self.out, "2026-10", check_only=True)
        self.assertEqual(code, 0)
        self.assertEqual(self.creates(), [])


if __name__ == "__main__":
    unittest.main()
