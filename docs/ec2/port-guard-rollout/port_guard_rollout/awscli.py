"""AWS CLI のコマンドを呼ぶ部分。

AWS SDK は使わず、作業者の PC に入っている `aws` を呼び、`--output json` の結果を読む。
認証情報・プロファイル・リージョンは AWS CLI の設定（環境変数を含む）をそのまま使う。
"""

import json
import os
import re
import shutil
import subprocess

# AWS CLI の誤りの表示: "An error occurred (Code) when calling the Operation operation: message"
_ERROR_PATTERN = re.compile(r"An error occurred \((?P<code>[^)]+)\)[^:]*:\s*(?P<message>.*)", re.DOTALL)


class AwsCliError(Exception):
    """AWS CLI のコマンドが失敗したとき。code は AWS の誤りのコード（取れなければ None）。"""

    def __init__(self, args, returncode, stderr):
        self.args_list = args
        self.returncode = returncode
        self.stderr = stderr.strip()
        match = _ERROR_PATTERN.search(self.stderr)
        self.code = match.group("code") if match else None
        self.message = match.group("message").strip() if match else self.stderr
        super().__init__(f"{self.code or 'error'}: {self.message}")


class AwsCli:
    """`aws` のコマンドを呼ぶ。profile と region を指定すると、すべての呼び出しに付ける。"""

    def __init__(self, profile=None, region=None, executable="aws"):
        self.profile = profile
        self.region = region
        self.executable = executable

    def available(self):
        return shutil.which(self.executable) is not None

    def run(self, *args):
        """コマンドを実行し、JSON の結果を返す（出力が空なら None）。失敗したら AwsCliError。"""
        command = [self.executable, *args, "--output", "json"]
        if self.profile:
            command += ["--profile", self.profile]
        if self.region:
            command += ["--region", self.region]
        env = dict(os.environ, AWS_PAGER="")
        completed = subprocess.run(command, capture_output=True, text=True, env=env)
        if completed.returncode != 0:
            raise AwsCliError(command, completed.returncode, completed.stderr)
        output = completed.stdout.strip()
        return json.loads(output) if output else None
