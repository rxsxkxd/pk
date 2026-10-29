"""遮断の有効化のテスト。SSH・SSM・接続の確認には接続せず、偽物で応答を返す。"""

import io
import unittest

from port_guard_rollout import enable
from port_guard_rollout.ssh import SshResult, parse_output

READY = {
    "os": "Amazon Linux release 2 (Karoo)", "systemd": "running",
    "firewalld_installed": "no", "firewalld_enabled": "none", "firewalld_active": "unknown",
    "iptables_services_installed": "no", "iptables_enabled": "none", "ipset_installed": "yes",
    "ipset_sets": "port_guard_jp,port_guard_allow", "iptables_other_rules": "0", "port_guard_jump": "0",
    "port_guard_installed": "yes", "python3": "yes", "docker_active": "inactive",
    "ports_current": "80,443", "allow_current": "203.0.113.10", "jp_min_entries": "1000",
    "jp_file_entries": "4738", "jp_set_entries": "4738", "allow_set_entries": "1", "revert_pending": "",
}
APPLIED = {"revert": "systemd:port-guard-auto-revert-x", "unit": "enabled", "ports": "80,443", "jump": "1",
           "chain_rules": "5", "jp_set_entries": "4738", "allow_set_entries": "1"}


def result(values=None, returncode=0, stderr="", steps=()):
    stdout = "".join(f"PGSTEP {s}\n" for s in steps) + "".join(f"PG {k}={v}\n" for k, v in (values or {}).items())
    return SshResult(returncode, stdout, stderr, *parse_output(stdout))


def kind_of(script):
    for marker, kind in (("enable-check", "check"), ("自動で元に戻る予約（", "apply"),
                         ("予約を取り消して確定", "confirm"), ("すぐに元に戻す", "revert"), ("reachable", "reach")):
        if marker in script:
            return kind
    return "check"


class FakeRemote:
    def __init__(self, checks, apply=None, reach=None):
        self.checks = checks
        self.apply = apply or {}
        self.reach = reach or {}
        self.calls = []

    def available(self):
        return True

    def run_script(self, target, script, timeout=900):
        kind = "check" if "PG os=" in script or "kv os " in script else kind_of(script)
        self.calls.append((kind, target))
        if kind == "check":
            return self.checks[target]
        if kind == "apply":
            return self.apply.get(target, result(APPLIED, steps=["有効化", "確認"]))
        if kind == "reach":
            return self.reach.get(target, result({"reachable": "yes"}))
        if kind == "confirm":
            return result({"cancelled": "x", "jump": "1"})
        return result({"jump": "0"})


class NoAws:
    def available(self):
        return False


class ClassifyTest(unittest.TestCase):
    def classify(self, overrides):
        host = enable.Host("i-00000001", "h")
        enable.classify_for_enable(host, result({**READY, **overrides}))
        return host

    def test_ready(self):
        host = self.classify({})
        self.assertTrue(host.enableable)
        self.assertEqual(host.ports, ["80", "443"])

    def test_not_installed_or_already_enabled_or_short_list(self):
        self.assertIn("先に install", self.classify({"port_guard_installed": "no"}).reasons[0])
        self.assertEqual(self.classify({"port_guard_jump": "1"}).reasons, ["遮断がすでに有効になっている"])
        self.assertIn("一覧が少ない", self.classify({"jp_file_entries": "10"}).reasons[0])
        self.assertIn("80,443 ではない", self.classify({"ports_current": "22,443"}).reasons[0])


class RunTest(unittest.TestCase):
    def setUp(self):
        self.stdin = io.StringIO("i-00000001 h1\ni-00000002 h2\ni-00000003 h3\n")
        self.out = io.StringIO()

    def calls(self, remote, kind):
        return [c[1] for c in remote.calls if c[0] == kind]

    def test_per_instance_checkpoint_confirm_and_revert(self):
        remote = FakeRemote(checks={"h1": result(READY), "h2": result(READY), "h3": result(READY)})
        answers = iter(["y", "n", "y"])
        connected = {"h1": True, "h3": False}
        code = enable.run(NoAws(), remote, self.stdin, self.out, ask_func=lambda q, c: next(answers),
                          connect=lambda a, p, t, k: connected[a])
        self.assertEqual(code, 1)
        self.assertEqual(self.calls(remote, "apply"), ["h1", "h3"])
        self.assertEqual(self.calls(remote, "confirm"), ["h1"])
        self.assertEqual(self.calls(remote, "revert"), ["h3"])
        output = self.out.getvalue()
        self.assertIn("確定 1 台、戻した 1 台、失敗 0 台、飛ばした 1 台", output)

    def test_quit_stops_remaining(self):
        remote = FakeRemote(checks={"h1": result(READY), "h2": result(READY), "h3": result(READY)})
        answers = iter(["y", "q"])
        enable.run(NoAws(), remote, self.stdin, self.out, ask_func=lambda q, c: next(answers),
                   connect=lambda a, p, t, k: True)
        self.assertEqual(self.calls(remote, "apply"), ["h1"])
        self.assertIn("止めたので行わなかった 2 台", self.out.getvalue())

    def test_lost_access_leaves_auto_revert(self):
        remote = FakeRemote(checks={"h1": result(READY)}, reach={"h1": result(returncode=255, stderr="timed out")})
        stdin = io.StringIO("i-00000001 h1\n")
        enable.run(NoAws(), remote, stdin, self.out, assume_yes=True, connect=lambda a, p, t, k: True)
        self.assertEqual(self.calls(remote, "confirm"), [])
        self.assertIn("予約で自動的に元に戻る", self.out.getvalue())

    def test_port_map_and_dry_run(self):
        remote = FakeRemote(checks={"h1": result(READY), "user@h1:2222": result(READY)})
        seen = []
        enable.run(NoAws(), remote, io.StringIO("i-00000001 user@h1:2222\n"), self.out, assume_yes=True,
                   port_map={"80": "8080", "443": "8443"}, connect=lambda a, p, t, k: seen.append((a, p, k)) or True)
        self.assertEqual(seen, [("h1", 8080, "http"), ("h1", 8443, "tls")])
        out = io.StringIO()
        code = enable.run(NoAws(), remote, io.StringIO("i-00000001 h1\n"), out, dry_run=True)
        self.assertEqual(code, 0)
        self.assertIn("dry 実行", out.getvalue())


class ProbeTest(unittest.TestCase):
    """作業者の PC から相手が応答するかの確かめ方。手元で小さなサーバーを立てて確かめる。"""

    def serve(self, reply):
        import socket
        import threading

        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)

        def handle():
            conn, _ = server.accept()
            with conn:
                try:
                    if reply is not None:
                        conn.sendall(reply)
                    conn.recv(100)
                except OSError:
                    pass  # 確認の側が先に切ることがある

        threading.Thread(target=handle, daemon=True).start()
        self.addCleanup(server.close)
        return server.getsockname()[1]

    def test_ssh_banner(self):
        self.assertTrue(enable.can_connect("127.0.0.1", self.serve(b"SSH-2.0-OpenSSH_7.4\r\n"), 2, "ssh"))

    def test_silent_server_fails_ssh_and_tls_but_passes_tcp(self):
        self.assertTrue(enable.can_connect("127.0.0.1", self.serve(None), 1, "tcp"))
        self.assertFalse(enable.can_connect("127.0.0.1", self.serve(None), 1, "ssh"))
        self.assertFalse(enable.can_connect("127.0.0.1", self.serve(None), 1, "tls"))


if __name__ == "__main__":
    unittest.main()
