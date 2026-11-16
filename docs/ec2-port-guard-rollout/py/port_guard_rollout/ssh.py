"""SSH でインスタンスに入り、シェルの処理を root で実行する部分。

作業者の PC の `ssh` を呼ぶ。鍵・踏み台・既知のホストなどは、作業者の SSH の設定をそのまま使い、
足りないものだけをオプションで足す。処理は標準入力で渡し、インスタンスの中で `sudo -n bash -s` で実行する。
"""

import shutil
import subprocess
from dataclasses import dataclass, field


@dataclass
class SshResult:
    returncode: int
    stdout: str
    stderr: str
    values: dict = field(default_factory=dict)  # "PG <キー>=<値>" の行
    steps: list = field(default_factory=list)   # "PGSTEP <内容>" の行

    @property
    def connection_failed(self):
        # ssh 自身の失敗（接続できない、認証できない）は 255
        return self.returncode == 255

    @property
    def sudo_failed(self):
        return "sudo:" in self.stderr and ("password" in self.stderr or "a terminal is required" in self.stderr)

    def error_summary(self, lines=3):
        text = (self.stderr or self.stdout).strip().splitlines()
        return " / ".join(text[-lines:]) if text else f"終了コード {self.returncode}"


def parse_output(stdout):
    values, steps = {}, []
    for line in stdout.splitlines():
        if line.startswith("PG ") and "=" in line:
            key, value = line[3:].split("=", 1)
            values[key] = value
        elif line.startswith("PGSTEP "):
            steps.append(line[7:])
    return values, steps


class SshClient:
    def __init__(self, user="centos", key=None, options=None, connect_timeout=10, executable="ssh"):
        self.user = user
        self.key = key
        self.options = options or []
        self.connect_timeout = connect_timeout
        self.executable = executable

    def available(self):
        return shutil.which(self.executable) is not None

    def command(self, target):
        """target は `host`、`host:port`、`user@host`、`user@host:port`。"""
        user = self.user
        if "@" in target:
            user, target = target.split("@", 1)
        host, _, port = target.partition(":")
        command = [
            self.executable,
            "-o", "BatchMode=yes",
            "-o", f"ConnectTimeout={self.connect_timeout}",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        for option in self.options:
            command += ["-o", option]
        if self.key:
            command += ["-i", self.key]
        if port:
            command += ["-p", port]
        command += [f"{user}@{host}", "sudo -n bash -s"]
        return command

    def run_script(self, target, script, timeout=900):
        try:
            completed = subprocess.run(
                self.command(target), input=script, capture_output=True, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            return SshResult(124, error.stdout or "", f"{timeout} 秒で終わらなかった")
        values, steps = parse_output(completed.stdout)
        return SshResult(completed.returncode, completed.stdout, completed.stderr, values, steps)
