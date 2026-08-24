"""海外からの確認の拠点で使う port-guard-probe のテスト。手元で小さなサーバーを立てて確かめる（外には接続しない）。"""

import importlib.machinery
import importlib.util
import io
import socket
import threading
import unittest
from pathlib import Path
from unittest import mock

PROBE_DIR = Path(__file__).resolve().parent.parent / "outside-probe"
SCRIPT = PROBE_DIR / "port-guard-probe"
TEMPLATE = PROBE_DIR / "image-builder" / "outside-probe-image.yml"


def load_probe():
    """拡張子のない実行ファイルを、モジュールとして読み込む。"""
    loader = importlib.machinery.SourceFileLoader("port_guard_probe", str(SCRIPT))
    spec = importlib.util.spec_from_loader("port_guard_probe", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


probe = load_probe()


class ProbeTest(unittest.TestCase):
    def serve(self, reply):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)

        def handle():
            try:
                conn, _ = server.accept()
            except OSError:
                return
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

    def free_port(self):
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        return port

    def test_reachable_kinds(self):
        self.assertEqual(probe.probe("127.0.0.1", self.serve(b"SSH-2.0-OpenSSH_7.4\r\n"), "ssh", 2)[0], "reachable")
        self.assertEqual(probe.probe("127.0.0.1", self.serve(b"HTTP/1.1 200 OK\r\n\r\n"), "http", 2)[0], "reachable")
        self.assertEqual(probe.probe("127.0.0.1", self.serve(None), "tcp", 1)[0], "reachable")

    def test_connected_but_no_protocol_response(self):
        self.assertEqual(probe.probe("127.0.0.1", self.serve(None), "tls", 1)[0], "no-response")
        self.assertEqual(probe.probe("127.0.0.1", self.serve(None), "ssh", 1)[0], "no-response")

    def test_refused(self):
        self.assertEqual(probe.probe("127.0.0.1", self.free_port(), "tcp", 1)[0], "refused")

    def test_timeout_is_reported_separately(self):
        with mock.patch.object(probe.socket, "create_connection", side_effect=socket.timeout()):
            self.assertEqual(probe.probe("192.0.2.1", 443, "tls", 1)[0], "timeout")

    def test_main_prints_values_and_exit_code(self):
        out = io.StringIO()
        port = self.free_port()
        code = probe.main(["127.0.0.1", f"{port}:tcp", "--timeout", "1"], out=out)
        self.assertEqual(code, 1)
        self.assertIn("PG target=127.0.0.1", out.getvalue())
        self.assertIn(f"PG probe_{port}=refused", out.getvalue())
        out = io.StringIO()
        self.assertEqual(probe.main(["127.0.0.1", f"{self.serve(None)}:tcp"], out=out), 0)

    def test_rejects_bad_spec(self):
        with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
            probe.main(["127.0.0.1", "443:ftp"], out=io.StringIO())


class TemplateTest(unittest.TestCase):
    """Image Builder のテンプレートに埋め込んだ port-guard-probe が、本体と同じ中身か。"""

    def template_lines(self):
        return TEMPLATE.read_text(encoding="utf-8").split("\n")

    def test_embedded_script_matches_source(self):
        lines = self.template_lines()
        start = next(i for i, l in enumerate(lines) if "<<'PORT_GUARD_PROBE_EOF'" in l) + 1
        end = next(i for i in range(start, len(lines)) if lines[i].strip() == "PORT_GUARD_PROBE_EOF")
        embedded = "\n".join(l[22:] for l in lines[start:end]) + "\n"
        self.assertEqual(embedded, SCRIPT.read_text(encoding="utf-8"),
                         "port-guard-probe を直したら、テンプレートの埋め込みも同じ中身に直し、版を上げる")

    def test_component_data_is_within_limit(self):
        lines = self.template_lines()
        start = lines.index("      Data: |") + 1
        end = next(i for i in range(start, len(lines)) if lines[i] and not lines[i].startswith("        "))
        data = "\n".join(l[8:] for l in lines[start:end])
        self.assertLessEqual(len(data), 16000)  # AWS::ImageBuilder::Component の Data の上限（未確認の値）


if __name__ == "__main__":
    unittest.main()
