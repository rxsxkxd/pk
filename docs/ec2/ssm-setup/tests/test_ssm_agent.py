"""SSM Agent のインストールのテスト。SSH と AWS には接続せず、偽物で応答を返す。"""

import io
import unittest

from ssm_setup import ssm_agent
from ssm_setup.ssh import SshResult, parse_output

BASE = {"os": "Amazon Linux release 2 (Karoo)", "systemd": "running", "imds": "yes",
        "instance_profile": "yes", "region": "ap-northeast-1", "ssm_endpoint": "reachable"}
NOT_INSTALLED = {**BASE, "agent_installed": "no", "agent_version": "", "agent_enabled": "none", "agent_active": "unknown"}
STOPPED = {**BASE, "agent_installed": "yes", "agent_version": "3.3.5390.0", "agent_enabled": "disabled", "agent_active": "inactive"}
RUNNING = {**BASE, "agent_installed": "yes", "agent_version": "3.3.5390.0", "agent_enabled": "enabled", "agent_active": "active"}
INSTALLED = {"installed": "now", "agent_version": "3.3.5390.0", "agent_enabled": "enabled",
             "agent_active": "active", "diagnostics_failed": "0"}


def result(values=None, returncode=0, stderr="", steps=()):
    stdout = "".join(f"PGSTEP {s}\n" for s in steps) + "".join(f"PG {k}={v}\n" for k, v in (values or {}).items())
    return SshResult(returncode, stdout, stderr, *parse_output(stdout))


class FakeSsh:
    def __init__(self, checks, installs=None):
        self.checks = checks
        self.installs = installs or {}
        self.calls = []

    def available(self):
        return True

    def run_script(self, target, script, timeout=900):
        kind = "install" if "systemctl enable amazon-ssm-agent" in script else "check"
        self.calls.append((kind, target))
        if kind == "check":
            return self.checks[target]
        return self.installs.get(target, result(INSTALLED, steps=["SSM Agent のインストール"]))


class FakeAws:
    """インスタンスの ID ごとの登録の状態。online_after に入れた ID は、2 回目以降の問い合わせで Online になる。"""

    def __init__(self, ping=None, online_after=()):
        self.ping = ping or {}
        self.online_after = set(online_after)
        self.asked = {}

    def available(self):
        return True

    def run(self, *args):
        assert args[:2] == ("ssm", "describe-instance-information")
        instance_id = args[3].split("Values=")[1]
        self.asked[instance_id] = self.asked.get(instance_id, 0) + 1
        status = self.ping.get(instance_id)
        if instance_id in self.online_after and self.asked[instance_id] >= 2:
            status = "Online"
        return {"InstanceInformationList": [{"PingStatus": status}] if status else []}


class DecideTest(unittest.TestCase):
    def decide(self, values, ping="未登録", use_aws=True, **kwargs):
        host = ssm_agent.Host("i-00000001", "h", ping_status=ping)
        ssm_agent.decide(host, kwargs.get("res") or result(values), use_aws)
        return host

    def test_actions(self):
        self.assertEqual(self.decide(NOT_INSTALLED).action, ssm_agent.INSTALL)
        self.assertEqual(self.decide(STOPPED).action, ssm_agent.ENABLE)
        self.assertEqual(self.decide(RUNNING).action, ssm_agent.RESTART)
        online = self.decide(RUNNING, ping="Online")
        self.assertEqual((online.action, online.reasons), ("", []))

    def test_running_without_profile_or_endpoint_cannot_be_fixed(self):
        self.assertIn("インスタンスプロファイルがない", self.decide({**RUNNING, "instance_profile": "no"}).reasons[0])
        self.assertIn("届かない", self.decide({**RUNNING, "ssm_endpoint": "unreachable"}).reasons[0])

    def test_notes_for_install(self):
        host = self.decide({**NOT_INSTALLED, "systemd": "not-running", "imds": "no", "instance_profile": ""},
                           ping="", use_aws=False)
        self.assertEqual(host.action, ssm_agent.INSTALL)
        self.assertTrue(any("systemd" in n for n in host.notes))
        self.assertTrue(any("メタデータ" in n for n in host.notes))

    def test_ssh_failure(self):
        host = self.decide(None, res=result(returncode=255, stderr="Permission denied (publickey)."))
        self.assertIn("SSH で入れない", host.reasons[0])


class RunTest(unittest.TestCase):
    def setUp(self):
        self.stdin = io.StringIO("i-00000001 h1\ni-00000002 h2\ni-00000003 h3\ni-00000004 h4\n")
        self.out = io.StringIO()
        self.ssh = FakeSsh(checks={
            "h1": result(NOT_INSTALLED), "h2": result(STOPPED), "h3": result(RUNNING),
            "h4": result({**RUNNING, "instance_profile": "no"}),
        })
        self.aws = FakeAws(ping={"i-00000003": "Online"}, online_after={"i-00000001", "i-00000002"})

    def installs(self):
        return [c[1] for c in self.ssh.calls if c[0] == "install"]

    def test_installs_serially_and_waits_for_online(self):
        code = ssm_agent.run(self.aws, self.ssh, self.stdin, self.out, wait_seconds=60,
                             confirm_func=lambda q: True, sleep=lambda s: None)
        self.assertEqual(self.installs(), ["h1", "h2"])
        output = self.out.getvalue()
        self.assertIn("Online: i-00000001", output)
        self.assertIn("Online: i-00000002", output)
        self.assertIn("インスタンスプロファイルがない", output)
        self.assertEqual(code, 1)  # h4 は対応できない

    def test_check_only(self):
        code = ssm_agent.run(self.aws, self.ssh, self.stdin, self.out, check_only=True)
        self.assertEqual(code, 0)
        self.assertEqual(self.installs(), [])

    def test_no_aws_requires_targets(self):
        stdin = io.StringIO("i-00000001\n")
        self.assertEqual(ssm_agent.run(self.aws, self.ssh, stdin, self.out, use_aws=False), 2)


if __name__ == "__main__":
    unittest.main()
