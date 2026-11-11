"""AWS の呼び出し（Python CLI 版。aws コマンドを子プロセスとして呼ぶ。標準ライブラリだけで動く）。

正本は docs/seq/_common/python/cli/aws_client.py。各ツールにあるのは sync-common.sh で写したものなので、直接編集しない。
パラメータは API の名前のまま --cli-input-json で渡す。ページ送りは CLI が全ページをたどる。
"""

import json
import os
import re
import subprocess

# boto3 と CLI でサービス名が違うもの
CLI_SERVICE_NAMES = {"s3": "s3api"}
ERROR_RE = re.compile(
    r"\((?P<code>[^)]+)\) when calling the (?P<operation>[A-Za-z0-9]+) operation"
    r"(?: \(reached max retries: \d+\))?: (?P<message>.*)",
    re.S,
)


class AwsError(Exception):
    def __init__(self, operation, code, message):
        super().__init__(f"{operation}: {code}: {message}")
        self.operation = operation
        self.code = code
        self.message = message


class Aws:
    def __init__(self):
        # 混み合っているときは CLI が自分で送る速さを落とす
        self.env = dict(os.environ, AWS_RETRY_MODE=os.environ.get("AWS_RETRY_MODE", "adaptive"), AWS_PAGER="")
        self.region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or self._configured_region()

    def _configured_region(self):
        p = subprocess.run(["aws", "configure", "get", "region"], capture_output=True, text=True,
                           env=self.env, stdin=subprocess.DEVNULL)
        return p.stdout.strip() or None

    def call(self, service, operation, params, region=None, paginate=True):
        cmd = ["aws", CLI_SERVICE_NAMES.get(service, service), operation.replace("_", "-"),
               "--cli-input-json", json.dumps(params), "--output", "json"]
        if region:
            cmd += ["--region", region]
        if not paginate:
            cmd.append("--no-paginate")
        p = subprocess.run(cmd, capture_output=True, text=True, env=self.env, stdin=subprocess.DEVNULL)
        if p.returncode != 0:
            m = ERROR_RE.search(p.stderr)
            if m:
                raise AwsError(m["operation"], m["code"], m["message"].strip())
            raise AwsError("".join(w.capitalize() for w in operation.split("_")), "Unknown", p.stderr.strip())
        return json.loads(p.stdout) if p.stdout.strip() else {}
