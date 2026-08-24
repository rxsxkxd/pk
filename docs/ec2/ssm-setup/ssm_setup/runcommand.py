"""SSM の Run Command で、インスタンスでシェルの処理を root として実行する部分。

AWS CLI の `aws ssm send-command`（`AWS-RunShellScript`）で処理を送り、`get-command-invocation` で結果を待つ。
処理は base64 にして 1 行のコマンド（`echo ... | base64 -d | bash`）として送る（引用符や改行の扱いで壊れないように）。
SSH と同じく、結果は SshResult（"PG <キー>=<値>" と "PGSTEP <内容>" の行を読んだもの）で返す。
"""

import base64
import json
import time

from .awscli import AwsCliError
from .ssh import SshResult, parse_output

# 結果が決まった状態（これ以外は待ち続ける）
FINAL_STATUSES = {"Success", "Failed", "TimedOut", "Cancelled", "Undeliverable", "Terminated", "Cancelling"}


class RunCommandClient:
    def __init__(self, aws, poll_interval=3, sleep=time.sleep, clock=time.monotonic):
        self.aws = aws
        self.poll_interval = poll_interval
        self.sleep = sleep
        self.clock = clock

    def available(self):
        return self.aws.available()

    def ping_status(self, instance_id):
        """SSM に登録されているか（Online / ConnectionLost / 未登録 / 不明）。"""
        try:
            response = self.aws.run(
                "ssm", "describe-instance-information", "--filters", f"Key=InstanceIds,Values={instance_id}",
            )
        except AwsCliError as error:
            return f"不明（{error.code or error.message}）"
        items = response.get("InstanceInformationList", []) if response else []
        return items[0].get("PingStatus", "不明") if items else "未登録"

    def run_script(self, instance_id, script, timeout=900):
        encoded = base64.b64encode(script.encode("utf-8")).decode("ascii")
        parameters = {
            "commands": [f"echo '{encoded}' | base64 -d | bash"],
            "executionTimeout": [str(timeout)],
        }
        try:
            response = self.aws.run(
                "ssm", "send-command",
                "--instance-ids", instance_id,
                "--document-name", "AWS-RunShellScript",
                "--comment", "ssm-setup",
                f"--parameters={json.dumps(parameters)}",
            )
        except AwsCliError as error:
            return SshResult(255, "", f"SSM のコマンドを送れない（{error}）")
        command_id = response["Command"]["CommandId"]

        deadline = self.clock() + timeout + 60
        while True:
            self.sleep(self.poll_interval)
            try:
                invocation = self.aws.run(
                    "ssm", "get-command-invocation", "--command-id", command_id, "--instance-id", instance_id,
                )
            except AwsCliError as error:
                if error.code == "InvocationDoesNotExist" and self.clock() < deadline:
                    continue  # 送った直後は、まだ結果の記録がない
                return SshResult(255, "", f"SSM のコマンドの結果を取れない（{error}）")
            status = invocation.get("Status", "")
            if status in FINAL_STATUSES:
                break
            if self.clock() >= deadline:
                return SshResult(124, "", f"SSM のコマンドが {timeout} 秒で終わらなかった（{status}、{command_id}）")

        stdout = invocation.get("StandardOutputContent", "")
        stderr = invocation.get("StandardErrorContent", "")
        code = invocation.get("ResponseCode", -1)
        if status in ("Undeliverable", "Cancelled", "Terminated", "Cancelling") or (status == "TimedOut" and code == -1):
            # インスタンスまで届いていない（SSH の接続の失敗に当たる）
            return SshResult(255, stdout, f"SSM のコマンドが届かない（{status}、{command_id}）")
        values, steps = parse_output(stdout)
        return SshResult(code if code >= 0 else 1, stdout, stderr, values, steps)
