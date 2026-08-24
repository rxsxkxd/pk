"""操作の前のバックアップの確認のテスト。AWS には接続せず、偽物で応答を返す。"""

import io
import unittest
from datetime import datetime, timezone

from port_guard_rollout import backups, install
from port_guard_rollout.awscli import AwsCliError

NOW = datetime(2026, 10, 29, 12, 0, 0, tzinfo=timezone.utc)


class FakeAws:
    def __init__(self, images=None, error=None):
        self.images = images or []
        self.error = error
        self.args = None

    def available(self):
        return True

    def run(self, *args):
        self.args = args
        if self.error:
            raise self.error
        return {"Images": self.images}


def image(image_id, created, state="available"):
    return {"ImageId": image_id, "CreationDate": created, "State": state}


class FindBackupTest(unittest.TestCase):
    def find(self, images=None, error=None):
        aws = FakeAws(images, error)
        result = backups.find_backup(aws, "i-00000001", "2026-10", now=NOW)
        return result, aws

    def test_filters_by_purpose_instance_and_label(self):
        _, aws = self.find([image("ami-1", "2026-10-29T08:00:00.000Z")])
        self.assertIn("Name=tag:BackupLabel,Values=2026-10", aws.args)
        self.assertIn("Name=tag:SourceInstanceId,Values=i-00000001", aws.args)
        self.assertIn("Name=tag:Purpose,Values=port-guard-rollout-backup", aws.args)

    def test_available_within_12_hours(self):
        result, _ = self.find([image("ami-old", "2026-10-28T08:00:00.000Z"), image("ami-new", "2026-10-29T08:00:00.000Z")])
        self.assertEqual((result.ok, result.image_id), (True, "ami-new"))

    def test_reasons(self):
        self.assertIn("バックアップ（AMI）がない", self.find([])[0].reason)
        self.assertIn("12 時間より前", self.find([image("ami-1", "2026-10-28T23:59:59.000Z")])[0].reason)
        self.assertIn("作成中", self.find([image("ami-1", "2026-10-29T11:50:00.000Z", "pending")])[0].reason)
        self.assertIn("使えない状態", self.find([image("ami-1", "2026-10-29T11:50:00.000Z", "failed")])[0].reason)
        error = AwsCliError(["aws"], 254, "An error occurred (UnauthorizedOperation) when calling the X operation: no")
        self.assertIn("確かめられない", self.find(error=error)[0].reason)

    def test_uses_older_available_when_newest_is_pending(self):
        result, _ = self.find([image("ami-a", "2026-10-29T09:00:00.000Z"),
                               image("ami-b", "2026-10-29T11:00:00.000Z", "pending")])
        self.assertEqual((result.ok, result.image_id), (True, "ami-a"))


class CommandIntegrationTest(unittest.TestCase):
    def test_install_skips_hosts_without_backup_before_connecting(self):
        from test_install import CLEAN_STATE, FakeSsh, NoAws, result

        ssh = FakeSsh(checks={"h1": result(CLEAN_STATE), "h2": result(CLEAN_STATE)})
        checker = lambda iid: backups.BackupCheck(iid == "i-00000001", "ami-1", "2026-10-29T08:00:00.000Z",
                                                  "" if iid == "i-00000001" else "バックアップ（AMI）がない")
        out = io.StringIO()
        code = install.run(NoAws(), ssh, io.StringIO("i-00000001 h1\ni-00000002 h2\n"), out,
                           backup_check=checker, confirm_func=lambda q: True)
        self.assertEqual(code, 1)
        self.assertEqual([c[1] for c in ssh.calls], ["h1", "h1"])  # h2 には確認も導入も行わない
        self.assertIn("バックアップ: ami-1", out.getvalue())
        self.assertIn("バックアップ（AMI）がない", out.getvalue())


if __name__ == "__main__":
    unittest.main()
