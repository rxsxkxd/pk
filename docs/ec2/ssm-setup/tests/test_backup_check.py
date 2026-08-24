"""バックアップがあるかの確認のテスト。AWS には接続せず、偽物で応答を返す。"""

import io
import unittest
from datetime import datetime, timezone

from ssm_setup import backup_check

NOW = datetime(2026, 10, 29, 12, 0, 0, tzinfo=timezone.utc)


class FakeAws:
    """インスタンスの ID ごとの AMI の一覧を返す。describe-images 以外は呼ばれないことも確かめる。"""

    def __init__(self, images, available=True):
        self.images = images
        self._available = available
        self.calls = []

    def available(self):
        return self._available

    def run(self, *args):
        self.calls.append(args)
        assert args[:2] == ("ec2", "describe-images"), args
        instance_id = next(a for a in args if a.startswith("Name=tag:SourceInstanceId,")).split("Values=")[1]
        return {"Images": self.images.get(instance_id, [])}


def image(image_id, created, state="available"):
    return {"ImageId": image_id, "CreationDate": created, "State": state}


class RunTest(unittest.TestCase):
    def setUp(self):
        self.out = io.StringIO()

    def test_splits_hosts_and_shows_age_and_remaining(self):
        aws = FakeAws({
            "i-00000001": [image("ami-ok", "2026-10-29T09:00:00.000Z")],
            "i-00000002": [image("ami-pending", "2026-10-29T11:50:00.000Z", "pending")],
        })
        stdin = io.StringIO("i-00000001 localhost:2222\ni-00000002\ni-00000003\n")
        code = backup_check.run(aws, stdin, self.out, "2026-10", now=NOW)
        self.assertEqual(code, 1)
        output = self.out.getvalue()
        self.assertIn("操作できる（条件に合うバックアップがある。1 台）", output)
        self.assertIn("i-00000001  ami-ok  作成 2026-10-29T09:00:00.000Z（3.0 時間前。期限まであと 9.0 時間）", output)
        self.assertIn("i-00000002  理由: バックアップ（ami-pending）がまだ作成中（pending）", output)
        self.assertIn("i-00000003  理由: バックアップ作業のタイミング「2026-10」のバックアップ（AMI）がない", output)
        self.assertTrue(all(c[:2] == ("ec2", "describe-images") for c in aws.calls))  # 読み取りだけ

    def test_all_ok(self):
        aws = FakeAws({"i-00000001": [image("ami-ok", "2026-10-29T09:00:00.000Z")]})
        self.assertEqual(backup_check.run(aws, io.StringIO("i-00000001\n"), self.out, "2026-10", now=NOW), 0)

    def test_input_and_tool_problems(self):
        aws = FakeAws({})
        self.assertEqual(backup_check.run(aws, io.StringIO("i-00000001\n"), self.out, "本番 10 月"), 2)
        self.assertEqual(backup_check.run(aws, io.StringIO("\n# none\n"), self.out, "2026-10"), 2)
        self.assertEqual(backup_check.run(FakeAws({}, available=False), io.StringIO("i-00000001\n"), self.out, "2026-10"), 2)
        self.assertEqual(aws.calls, [])


if __name__ == "__main__":
    unittest.main()
