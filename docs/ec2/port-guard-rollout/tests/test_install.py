"""ipset の導入と設定のテスト。SSH と AWS には接続せず、偽物で応答を返す。"""

import io
import unittest

from port_guard_rollout import install
from port_guard_rollout.ssh import SshClient, SshResult, parse_output

CLEAN_STATE = {
    "os": "Amazon Linux release 2 (Karoo)", "systemd": "running",
    "firewalld_installed": "no", "firewalld_enabled": "none", "firewalld_active": "unknown",
    "iptables_services_installed": "no", "iptables_enabled": "none",
    "ipset_installed": "no", "ipset_sets": "", "iptables_other_rules": "0",
    "port_guard_jump": "0", "port_guard_installed": "no", "python3": "yes", "docker_active": "inactive",
}

INSTALLED = {
    "ipset_unit_enabled": "none", "unit": "registered", "jp_entries": "3500", "allow_entries": "2",
    "port_guard_jump": "0", "port_guard_unit_enabled": "disabled",
    "check_in_jp_203.0.113.10": "yes", "check_outside_198.51.100.1": "jp=no,allow=no",
}


def result(values=None, returncode=0, stderr="", steps=()):
    stdout = "".join(f"PGSTEP {s}\n" for s in steps) + "".join(f"PG {k}={v}\n" for k, v in (values or {}).items())
    return SshResult(returncode, stdout, stderr, *parse_output(stdout))


class FakeSsh:
    """接続先ごとに、確認（check.sh）と導入（install.sh）の結果を決めておく。"""

    def __init__(self, checks, installs=None):
        self.checks = checks
        self.installs = installs or {}
        self.calls = []

    def available(self):
        return True

    def run_script(self, target, script, timeout=900):
        kind = "install" if "PG_PORTS=" in script else "check"
        self.calls.append((kind, target, script))
        if kind == "check":
            return self.checks[target]
        return self.installs.get(target, result(INSTALLED, steps=["パッケージ（ipset、python3）", "確認"]))


class NoAws:
    def available(self):
        return False


class FakeRunCommand(FakeSsh):
    """SSM の Run Command の偽物。接続先はインスタンスの ID。登録の状態も返す。"""

    def __init__(self, checks, ping, installs=None):
        super().__init__(checks, installs)
        self.ping = ping

    def ping_status(self, instance_id):
        return self.ping.get(instance_id, "未登録")


class ClassifyTest(unittest.TestCase):
    def classify(self, overrides=None, **kwargs):
        host = install.Host("i-00000001", "h")
        install.classify(host, kwargs.get("res") or result({**CLEAN_STATE, **(overrides or {})}))
        return host

    def test_clean_instance_is_installable(self):
        self.assertTrue(self.classify().installable)

    def test_blockers(self):
        cases = {
            "firewalld が動いている": {"firewalld_active": "active"},
            "firewalld が起動時に有効": {"firewalld_enabled": "enabled"},
            "iptables のサービス": {"iptables_enabled": "enabled"},
            "すでに有効": {"port_guard_jump": "1"},
            "既存の iptables のルール": {"iptables_other_rules": "3"},
            "既存の ipset の集合": {"ipset_sets": "blacklist,port_guard_jp"},
            "Amazon Linux 2 ではない": {"os": "Amazon Linux release 2023.12.20261026 (Amazon Linux)"},
        }
        for expected, overrides in cases.items():
            with self.subTest(expected):
                host = self.classify(overrides)
                self.assertFalse(host.installable)
                self.assertIn(expected, " ".join(host.reasons))

    def test_ssh_and_sudo_failures(self):
        host = self.classify(res=result(returncode=255, stderr="ssh: connect to host h port 22: Connection refused"))
        self.assertIn("接続できない", host.reasons[0])
        host = self.classify(res=result(returncode=1, stderr="sudo: a password is required"))
        self.assertIn("sudo", host.reasons[0])

    def test_notes_do_not_block(self):
        host = self.classify({"port_guard_installed": "yes", "systemd": "not-running"})
        self.assertTrue(host.installable)
        self.assertEqual(len(host.notes), 2)


class BuildScriptTest(unittest.TestCase):
    def test_script_has_values_and_body(self):
        script = install.build_install_script("80,443", "203.0.113.10\n", 1000, ["203.0.113.10"], [])
        self.assertTrue(script.startswith("PG_PORTS=80,443\n"))
        self.assertIn("PG_CHECK_IN_JP=203.0.113.10\n", script)
        self.assertIn("PG_APPLY_B64=", script)
        self.assertIn('step "パッケージ（ipset、python3）"', script)


class SshCommandTest(unittest.TestCase):
    def test_target_forms(self):
        ssh = SshClient(user="centos", key="k", options=["UserKnownHostsFile=/dev/null"])
        command = ssh.command("ec2-user@localhost:2222")
        self.assertEqual(command[-2:], ["ec2-user@localhost", "sudo -n bash -s"])
        self.assertIn("2222", command)
        self.assertIn("UserKnownHostsFile=/dev/null", command)
        self.assertEqual(ssh.command("10.0.0.5")[-2], "centos@10.0.0.5")


class RunTest(unittest.TestCase):
    def setUp(self):
        self.stdin = io.StringIO("i-00000001 host1\ni-00000002 host2\ni-00000003 host3\n")
        self.out = io.StringIO()
        self.ssh = FakeSsh(
            checks={
                "host1": result(CLEAN_STATE),
                "host2": result({**CLEAN_STATE, "firewalld_active": "active"}),
                "host3": result(CLEAN_STATE),
            },
            installs={"host3": result(returncode=1, stderr="curl: (6) Could not resolve host",
                                      steps=["パッケージ（ipset、python3）", "日本の IP の範囲の取得と、集合の作成"])},
        )

    def installs(self):
        return [c[1] for c in self.ssh.calls if c[0] == "install"]

    def run_install(self, **kwargs):
        return install.run(NoAws(), self.ssh, self.stdin, self.out,
                           check_in_jp=["203.0.113.10"], check_outside=["198.51.100.1"], **kwargs)

    def test_installs_serially_after_confirmation(self):
        code = self.run_install(confirm_func=lambda q: True)
        self.assertEqual(code, 1)  # host2 は対象外、host3 は失敗
        self.assertEqual(self.installs(), ["host1", "host3"])
        output = self.out.getvalue()
        self.assertIn("完了: 日本の範囲 3500 件", output)
        self.assertIn("「日本の IP の範囲の取得と、集合の作成」で失敗", output)
        self.assertIn("firewalld が動いている", output)

    def test_check_only_and_decline_do_not_install(self):
        self.assertEqual(self.run_install(check_only=True), 0)
        self.assertEqual(self.installs(), [])

    def test_declined(self):
        self.assertEqual(self.run_install(confirm_func=lambda q: False), 0)
        self.assertEqual(self.installs(), [])

    def test_dry_run_shows_plan_and_changes_without_installing(self):
        self.ssh.checks["host1"] = result({**CLEAN_STATE, "port_guard_installed": "yes",
                                           "ports_current": "443", "allow_current": "198.51.100.0/24,203.0.113.10"})
        code = install.run(NoAws(), self.ssh, self.stdin, self.out,
                           allow_text="203.0.113.10\n192.0.2.1 # new\n", dry_run=True)
        self.assertEqual(code, 0)
        self.assertEqual(self.installs(), [])
        output = self.out.getvalue()
        self.assertIn("ポート 443 → 80,443", output)
        self.assertIn("許可する IP を足す: 192.0.2.1", output)
        self.assertIn("許可する IP を消す: 198.51.100.0/24", output)
        self.assertIn("dry 実行", output)

    def test_via_ssm_uses_instance_ids_and_requires_online(self):
        remote = FakeRunCommand(
            checks={"i-00000001": result(CLEAN_STATE)},
            ping={"i-00000001": "Online", "i-00000002": "ConnectionLost"},
        )
        stdin = io.StringIO("i-00000001\ni-00000002\n")
        code = install.run(NoAws(), remote, stdin, self.out, via="ssm", confirm_func=lambda q: True)
        self.assertEqual(code, 1)  # i-00000002 は SSM で操作できない
        self.assertEqual([c[1] for c in remote.calls if c[0] == "install"], ["i-00000001"])
        self.assertIn("SSM で操作できない（ConnectionLost）", self.out.getvalue())

    def test_include_ssh_shows_caution(self):
        code = install.run(NoAws(), self.ssh, self.stdin, self.out, ports=install.TARGET_PORTS_WITH_SSH, dry_run=True)
        self.assertEqual(code, 0)
        self.assertIn("PORT_GUARD_PORTS=22,80,443", self.out.getvalue())
        self.assertIn("22 番（SSH）も対象にする", self.out.getvalue())

    def test_needs_aws_when_target_is_missing(self):
        self.stdin = io.StringIO("i-00000001\n")
        self.assertEqual(self.run_install(confirm_func=lambda q: True), 2)


if __name__ == "__main__":
    unittest.main()
