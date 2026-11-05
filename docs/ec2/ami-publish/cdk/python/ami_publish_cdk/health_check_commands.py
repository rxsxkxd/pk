"""ヘルスチェックの SSM ドキュメントがリリース用インスタンス上で実行するコマンド。

仕組みの生成ツール（Go の internal/definitions の healthCheckCommands）を写したもの。変えるときは両方を直す。
5 秒間隔で最大 30 回アクセスし、2xx が返れば成功。失敗時は最後の HTTP ステータスを出す（認証情報は出さない）。
Basic 認証の情報は、curl にコマンドライン引数ではなく標準入力（-K -）で渡す。
"""

from __future__ import annotations

from .configuration import Environment


def health_check_commands(environment: Environment) -> list[str]:
    settings = environment.health_check
    commands = ["set -u"]
    curl_options = "-sS -o /dev/null -w '%{http_code}'"
    curl_prefix = ""
    if settings.basic_auth_parameter_name:
        name = settings.basic_auth_parameter_name
        commands += [
            "if ! command -v aws >/dev/null 2>&1; then echo 'health check failed: AWS CLI is not installed "
            "(needed to read the basic auth parameter)'; exit 1; fi",
            f"if ! credentials=$(aws ssm get-parameter --region {environment.aws_region} --name '{name}' "
            "--with-decryption --query Parameter.Value --output text); then "
            f"echo 'health check failed: cannot read the basic auth parameter {name} (check the release instance role)'; "
            "exit 1; fi",
            # curl の設定ファイル形式（user = "..."）で標準入力から渡す。" と \ はエスケープする
            r"""escaped=$(printf '%s' "$credentials" | sed 's/[\\"]/\\&/g')""",
            r"""basic_auth() { printf 'user = "%s"\n' "$escaped"; }""",
        ]
        curl_prefix = "basic_auth | "
        curl_options = "-K - " + curl_options
    commands += [
        "status=none",
        "for _ in $(seq 1 30); do",
        f"  status=$({curl_prefix}curl {curl_options} {settings.url} || true)",
        """  case "$status" in 2??) echo 'health check passed'; exit 0 ;; esac""",
        "  sleep 5",
        "done",
        f'echo "health check failed: {settings.url} did not respond with 2xx (last HTTP status: $status)"',
        """if [ "$status" = 401 ]; then echo 'HTTP 401: the basic auth credentials were rejected or not sent'; fi""",
        "exit 1",
    ]
    return commands
