"""IAM ロールの関連付けのテスト。AWS には接続せず、偽物の AWS CLI で応答を返す。"""

import io
import unittest

from ssm_setup import ssm_role
from ssm_setup.awscli import AwsCliError


def aws_error(code):
    return AwsCliError(["aws"], 254, f"An error occurred ({code}) when calling the Op operation: x")


class FakeAws:
    def __init__(self, instances, associations=None, profile=True):
        self.instances = instances  # インスタンスの ID → 状態
        self.associations = dict(associations or {})  # インスタンスの ID → インスタンスプロファイルの ARN
        self.profile = profile
        self.associated = []

    def available(self):
        return True

    def run(self, *args):
        if args[:2] == ("iam", "get-instance-profile"):
            if not self.profile:
                raise aws_error("NoSuchEntity")
            return {"InstanceProfile": {"Roles": [{"RoleName": "port-guard-ssm"}]}}
        if args[:2] == ("ec2", "describe-instances"):
            instance_id = args[3]
            if instance_id not in self.instances:
                raise aws_error("InvalidInstanceID.NotFound")
            return {"Reservations": [{"Instances": [{"State": {"Name": self.instances[instance_id]},
                                                      "Tags": [{"Key": "Name", "Value": "web"}]}]}]}
        if args[:2] == ("ec2", "describe-iam-instance-profile-associations"):
            instance_id = args[3].split("Values=")[1]
            arn = self.associations.get(instance_id)
            return {"IamInstanceProfileAssociations": [
                {"State": "associated", "IamInstanceProfile": {"Arn": arn}, "AssociationId": "a-1"}] if arn else []}
        if args[:2] == ("ec2", "associate-iam-instance-profile"):
            instance_id = args[args.index("--instance-id") + 1]
            self.associated.append((instance_id, args[args.index("--iam-instance-profile") + 1]))
            self.associations[instance_id] = "arn:aws:iam::1:instance-profile/port-guard-ssm"
            return {"IamInstanceProfileAssociation": {"State": "associating"}}
        raise AssertionError(args)


class RunTest(unittest.TestCase):
    def setUp(self):
        self.aws = FakeAws(
            instances={"i-00000001": "running", "i-00000002": "stopped", "i-00000003": "running",
                       "i-00000004": "terminated"},
            associations={"i-00000003": "arn:aws:iam::1:instance-profile/existing"},
        )
        self.stdin = io.StringIO("i-00000001\ni-00000002\ni-00000003\ni-00000004\ni-00000009\n")
        self.out = io.StringIO()

    def run_role(self, **kwargs):
        return ssm_role.run(self.aws, self.stdin, self.out, sleep=lambda s: None, **kwargs)

    def test_associates_only_instances_without_role(self):
        code = self.run_role(confirm_func=lambda q: True)
        self.assertEqual(code, 1)  # 対象外が 2 台ある
        self.assertEqual(self.aws.associated, [("i-00000001", "Name=port-guard-ssm"),
                                               ("i-00000002", "Name=port-guard-ssm")])
        output = self.out.getvalue()
        self.assertIn("関連付けた 2 台、失敗 0 台、何もしない 1 台、対象外 2 台", output)
        self.assertIn("arn:aws:iam::1:instance-profile/existing", output)

    def test_check_only_and_decline(self):
        self.assertEqual(self.run_role(check_only=True), 0)
        self.assertEqual(self.aws.associated, [])
        self.stdin.seek(0)
        self.assertEqual(self.run_role(confirm_func=lambda q: False), 0)
        self.assertEqual(self.aws.associated, [])

    def test_missing_profile_shows_creation_commands(self):
        self.aws.profile = False
        self.assertEqual(self.run_role(confirm_func=lambda q: True), 2)
        self.assertIn("aws iam create-instance-profile --instance-profile-name port-guard-ssm", self.out.getvalue())
        self.assertEqual(self.aws.associated, [])

    def test_skips_instance_associated_after_check(self):
        original = self.aws.run

        def run(*args):
            # 確かめた後、関連付けの直前に、ほかの人が関連付けた場合
            if args[:2] == ("ec2", "describe-iam-instance-profile-associations") and self.confirmed:
                self.aws.associations.setdefault("i-00000001", "arn:aws:iam::1:instance-profile/other")
            return original(*args)

        self.confirmed = False
        self.aws.run = run

        def confirm(question):
            self.confirmed = True
            return True

        self.run_role(confirm_func=confirm)
        self.assertEqual([a[0] for a in self.aws.associated], ["i-00000002"])
        self.assertIn("すでに関連付けられている", self.out.getvalue())


if __name__ == "__main__":
    unittest.main()
