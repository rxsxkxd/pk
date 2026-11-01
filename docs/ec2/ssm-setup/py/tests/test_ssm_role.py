"""IAM ロールの関連付けのテスト。AWS には接続せず、偽物の AWS CLI で応答を返す。"""

import io
import unittest

from ssm_setup import ssm_role
from ssm_setup.awscli import AwsCliError


def aws_error(code):
    return AwsCliError(["aws"], 254, f"An error occurred ({code}) when calling the Op operation: x")


class FakeAws:
    def __init__(self, instances, associations=None, profile=True, core=True):
        self.instances = instances  # インスタンスの ID → 状態
        self.associations = dict(associations or {})  # インスタンスの ID → インスタンスプロファイルの ARN
        self.profile = profile
        self.core = core  # ロールに AmazonSSMManagedInstanceCore が付いているか
        self.associated = []

    def available(self):
        return True

    def run(self, *args):
        if args[:2] == ("iam", "get-instance-profile"):
            if not self.profile:
                raise aws_error("NoSuchEntity")
            return {"InstanceProfile": {"Roles": [{"RoleName": "port-guard-ssm"}]}}
        if args[:2] == ("iam", "list-attached-role-policies"):
            names = ["AmazonSSMManagedInstanceCore"] if self.core else ["app-policy"]
            return {"AttachedPolicies": [{"PolicyName": n} for n in names]}
        if args[:2] == ("ec2", "describe-instances"):
            ids = args[3].split("Values=")[1].split(",")
            return {"Reservations": [{"Instances": [
                {"InstanceId": i, "State": {"Name": self.instances[i]}, "Tags": [{"Key": "Name", "Value": "web"}]}
                for i in ids if i in self.instances]}]}
        if args[:2] == ("ec2", "describe-iam-instance-profile-associations"):
            ids = args[3].split("Values=")[1].split(",")
            return {"IamInstanceProfileAssociations": [
                {"InstanceId": i, "State": "associated", "IamInstanceProfile": {"Arn": self.associations[i]}}
                for i in ids if i in self.associations]}
        if args[:2] == ("ec2", "associate-iam-instance-profile"):
            instance_id = args[args.index("--instance-id") + 1]
            if instance_id in self.associations:
                raise aws_error("IncorrectState")
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
        return ssm_role.run(self.aws, self.stdin, self.out, **kwargs)

    def test_associates_only_instances_without_role(self):
        code = self.run_role(confirm_func=lambda q: True)
        self.assertEqual(code, 1)  # 対象外が 2 台ある
        self.assertEqual(self.aws.associated, [("i-00000001", "Name=port-guard-ssm"),
                                               ("i-00000002", "Name=port-guard-ssm")])
        output = self.out.getvalue()
        self.assertIn("完了 2 台、失敗 0 台、何もしない 1 台、対象外 2 台", output)
        self.assertIn("arn:aws:iam::1:instance-profile/existing", output)
        self.assertIn("i-00000004  web  理由: 状態が terminated", output)
        self.assertIn("i-00000009    理由: 見つからない", output)
        self.assertIn("関連付け: i-00000001  あり", output)
        self.assertIn("port-guard-ssm のロールに AmazonSSMManagedInstanceCore が付いている", output)

    def test_role_without_core_policy_fails_permission_check(self):
        self.aws.core = False
        self.stdin = io.StringIO("i-00000001\n")
        self.assertEqual(self.run_role(confirm_func=lambda q: True), 1)
        self.assertEqual(self.aws.associated, [("i-00000001", "Name=port-guard-ssm")])
        self.assertIn("付いていない（このままでは Online にならない）", self.out.getvalue())

    def test_all_associated_and_permitted(self):
        self.stdin = io.StringIO("i-00000001\n")
        self.assertEqual(self.run_role(confirm_func=lambda q: True), 0)

    def test_check_only_and_decline(self):
        self.assertEqual(self.run_role(check_only=True), 0)
        self.assertEqual(self.aws.associated, [])
        self.stdin.seek(0)
        self.assertEqual(self.run_role(confirm_func=lambda q: False), 0)
        self.assertEqual(self.aws.associated, [])

    def test_missing_profile_stops(self):
        self.aws.profile = False
        self.assertEqual(self.run_role(confirm_func=lambda q: True), 2)
        self.assertIn("NoSuchEntity", self.out.getvalue())
        self.assertEqual(self.aws.associated, [])

    def test_associated_after_check_is_failure(self):
        def confirm(question):
            # 確かめた後、関連付けの前に、ほかの人が関連付けた場合（AWS の側が拒む）
            self.aws.associations["i-00000001"] = "arn:aws:iam::1:instance-profile/other"
            return True

        self.assertEqual(self.run_role(confirm_func=confirm), 1)
        self.assertEqual([a[0] for a in self.aws.associated], ["i-00000002"])
        self.assertIn("失敗: IncorrectState", self.out.getvalue())
        self.assertIn("完了 1 台、失敗 1 台", self.out.getvalue())


if __name__ == "__main__":
    unittest.main()
