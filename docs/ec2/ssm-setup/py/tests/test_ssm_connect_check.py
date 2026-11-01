"""実接続の確認（echo を流す）のテスト。AWS には接続せず、偽物で応答を返す。"""

import io
import os
import tempfile
import unittest

from ssm_setup import ssm_connect_check
from ssm_setup.ssh import SshResult
from ssm_setup.targets import read_targets

MARKER = "ssm-setup-connect-test"


class FakeAws:
    def __init__(self, session_ok=()):
        self.session_ok = set(session_ok)  # Session Manager で echo が返るインスタンスの ID
        self.sessions = []
        self.calls = []

    def available(self):
        return True

    def run(self, *args):
        self.calls.append(args[:2])  # 事前の確認（describe-* など）は呼ばないはず
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
            return SshResult(0, f"PG connect_check={MARKER}\n", "", {"connect_check": MARKER})
        return SshResult(255, "", "SSM のコマンドが届かない（Undeliverable、c-1）")


class RunTest(unittest.TestCase):
    def setUp(self):
        self.aws = FakeAws(session_ok={"i-00000001"})
        self.runner = FakeRunner(ok={"i-00000001"})
        self.stdin = io.StringIO("i-00000001\ni-00000002\n")
        self.out = io.StringIO()

    def run_check(self, **kwargs):
        kwargs.setdefault("plugin_available", True)
        return ssm_connect_check.run(self.aws, self.runner, self.stdin, self.out, make_marker=lambda: MARKER, **kwargs)

    def test_session_route_skips_prechecks(self):
        self.assertEqual(self.run_check(), 1)
        self.assertEqual(self.aws.sessions, [("i-00000001", "AWS-StartNonInteractiveCommand"),
                                             ("i-00000002", "AWS-StartNonInteractiveCommand")])
        self.assertEqual(self.aws.calls, [])  # 事前の確認はしない
        self.assertEqual(self.runner.sent, [])
        output = self.out.getvalue()
        self.assertIn("入れる    i-00000001", output)
        self.assertIn("入れない  i-00000002  Session Manager でつながらない（An error occurred (AccessDeniedException)", output)
        self.assertIn("結果: 入れる 1 台、入れない 1 台", output)

    def test_run_command_route(self):
        self.assertEqual(self.run_check(via="run-command"), 1)
        self.assertEqual(self.runner.sent, ["i-00000001", "i-00000002"])
        self.assertEqual(self.aws.sessions, [])
        self.assertIn("Run Command でつながらない（SSM のコマンドが届かない（Undeliverable、c-1））", self.out.getvalue())

    def test_all_connected(self):
        self.stdin = io.StringIO("i-00000001\n")
        self.assertEqual(self.run_check(), 0)

    def test_ok_out_and_ng_out(self):
        with tempfile.TemporaryDirectory() as directory:
            ok_path, ng_path = os.path.join(directory, "ok.txt"), os.path.join(directory, "connect-ng.txt")
            self.run_check(ok_out=ok_path, ng_out=ng_path)
            with open(ok_path, encoding="utf-8") as f:
                ok_text = f.read()
            with open(ng_path, encoding="utf-8") as f:
                ng_text = f.read()
        self.assertEqual([t.instance_id for t in read_targets(io.StringIO(ok_text))[0]], ["i-00000001"])
        # 入れなかった台は # で消さない（直した後に、そのまま渡し直せる）
        self.assertEqual([t.instance_id for t in read_targets(io.StringIO(ng_text))[0]], ["i-00000002"])
        self.assertIn("i-00000002  # Session Manager でつながらない", ng_text)

    def test_missing_plugin(self):
        self.assertEqual(self.run_check(plugin_available=False), 2)
        self.assertIn("--via run-command", self.out.getvalue())
        self.assertEqual(self.aws.sessions, [])


if __name__ == "__main__":
    unittest.main()
