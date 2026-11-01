"""SSM Agent のインストールと有効化（設計の「SSM の準備」）。

確かめる（plan）: SSH の接続先を決め（書かれていなければ、AWS CLI でインスタンスの IP を引く）、1 台ずつ SSH で入って
  SSM Agent の状態を読み、AWS の側の登録の状態も見て、行うこと（インストール・有効化・起動し直し）・何もしない・
  対応できない（理由つき）に分ける
行う（apply）: 1 台ずつ順に、SSM Agent を入れて、起動時に有効にして起動し直す
後（finish）: AWS の側で登録されたか（`Online`）を、決めた時間まで待って確かめる

入力・表示・確認・失敗の扱いは flow の共通の流れ。

インスタンスプロファイルや IAM の権限の付与は行わない（別の作業）。
権限のないインスタンスは、入れても `Online` にならないことを表示する。
"""

import time
from dataclasses import dataclass, field
from pathlib import Path

from ssm_setup_backup.backups import apply_check

from .awscli import AwsCliError
from .console import confirm
from .flow import Failed, Item, Plan, execute, require
from .targets import resolve_ssh_target

REMOTE_DIR = Path(__file__).parent / "remote"

INSTALL = "インストール"
ENABLE = "有効化と起動"
RESTART = "起動し直し"


@dataclass
class Host:
    instance_id: str
    ssh_target: str = ""
    name: str = ""
    state: dict = field(default_factory=dict)  # 今の状態（agent-check.sh の結果）
    ping_status: str = ""  # AWS の側の登録の状態（Online / ConnectionLost / 未登録。AWS を見ないときは空）
    action: str = ""  # 行うこと（空なら何もしない）
    reasons: list = field(default_factory=list)  # 対応できない理由
    notes: list = field(default_factory=list)  # 知らせておくこと
    backup: str = ""  # 確かめたバックアップ（AMI の ID と作成の時刻）


def remote_file(name):
    return (REMOTE_DIR / name).read_text(encoding="utf-8")


def fetch_ping_status(aws, instance_id):
    """AWS の側の登録の状態。登録されていなければ "未登録"、取れなければ "不明（理由）"。"""
    try:
        response = aws.run(
            "ssm", "describe-instance-information",
            "--filters", f"Key=InstanceIds,Values={instance_id}",
        )
    except AwsCliError as error:
        return f"不明（{error.code or error.message}）"
    items = response.get("InstanceInformationList", []) if response else []
    return items[0].get("PingStatus", "不明") if items else "未登録"


def decide(host, result, use_aws):
    """agent-check.sh の結果と登録の状態から、行うことと、対応できない理由を決める。"""
    if result.connection_failed:
        host.reasons.append(f"SSH で入れない（{result.error_summary(1)}）")
        return
    if result.sudo_failed:
        host.reasons.append("sudo をパスワードなしで使えない")
        return
    if result.returncode != 0 or "os" not in result.values:
        host.reasons.append(f"状態を確かめられない（{result.error_summary()}）")
        return

    s = host.state = result.values
    if "Amazon Linux release 2 " not in s["os"] + " ":
        host.reasons.append(f"Amazon Linux 2 ではない（{s['os']}）")
        return

    if host.ping_status == "Online":
        return  # すでに使える
    if s.get("agent_installed") != "yes":
        host.action = INSTALL
    elif s.get("agent_enabled") != "enabled" or s.get("agent_active") != "active":
        host.action = ENABLE
    elif s.get("instance_profile") == "no":
        host.reasons.append("動いているが、インスタンスプロファイルがない（権限の付与は別の作業）")
    elif s.get("ssm_endpoint") == "unreachable":
        host.reasons.append("動いているが、AWS の窓口（ssm）に届かない（ネットワークの見直しが要る）")
    elif use_aws:
        host.action = RESTART  # 動いているのに登録されていない。認証情報を取り直させる

    if host.action:
        if s.get("systemd") != "running":
            host.notes.append("systemd が動いていない（インストールだけ行い、起動は飛ばす）")
        if s.get("instance_profile") == "no":
            host.notes.append("インスタンスプロファイルがない（入れても Online にならない。権限の付与は別の作業）")
        if s.get("imds") == "no":
            host.notes.append("インスタンスのメタデータに届かない（EC2 ではない、または止めている）")
        if s.get("ssm_endpoint") == "unreachable":
            host.notes.append("AWS の窓口（ssm）に届かない（入れても Online にならない）")


def wait_online(aws, hosts, out, timeout, interval=10, sleep=time.sleep, clock=time.monotonic):
    """AWS の側で Online になるまで待つ。戻り値は Online にならなかったインスタンスの ID の一覧。"""
    pending = {h.instance_id for h in hosts}
    deadline = clock() + timeout
    print(f"\n== 登録（Online）を待つ（最大 {timeout} 秒）", file=out)
    while pending:
        for instance_id in sorted(pending):
            status = fetch_ping_status(aws, instance_id)
            if status == "Online":
                pending.discard(instance_id)
                print(f"  Online: {instance_id}", file=out)
        if not pending or clock() >= deadline:
            break
        sleep(interval)
    for instance_id in sorted(pending):
        print(f"  Online にならなかった: {instance_id}", file=out)
    return sorted(pending)


def plan(aws, ssh, targets, out, address, use_aws, backup_check):
    require(ssh.available(), "ssh のコマンドが見つからない")
    require(use_aws or all(t.ssh_target for t in targets), "--no-aws のときは、すべての行に SSH の接続先を書く")
    require(not use_aws or aws.available(), "aws のコマンドが見つからない（AWS CLI を入れるか、--no-aws を付けて接続先を書く）")

    print(f"{len(targets)} 台を確かめる（SSH で入って、SSM Agent の状態を読むだけ）", file=out)
    p = Plan(title="行うこと", question="SSM Agent のインストール・有効化・起動を試行しますか？",
             excluded_title="対応できない")
    check_script = remote_file("agent-check.sh")
    for target in targets:
        host = Host(target.instance_id, target.ssh_target)
        apply_check(backup_check, host)
        if use_aws and not host.reasons:
            resolve_ssh_target(aws, host, address)
        if not host.reasons:
            if use_aws:
                host.ping_status = fetch_ping_status(aws, host.instance_id)
            print(f"  確認中: {host.instance_id}  {host.ssh_target}", file=out)
            decide(host, ssh.run_script(host.ssh_target, check_script, timeout=120), use_aws)
        ping = host.ping_status or "見ていない"
        if host.reasons:
            p.excluded.append(f"{host.instance_id}  {host.name}  {host.ssh_target}  理由: {' / '.join(host.reasons)}")
        elif not host.action:
            p.keep.append(f"{host.instance_id}  {host.name}  {host.ssh_target}  すでに使える（登録: {ping}）")
        else:
            details = [f"今の SSM Agent: {host.state.get('agent_version') or 'なし'}、登録: {ping}"]
            details += [f"注意: {note}" for note in host.notes]
            details += [f"バックアップ: {host.backup}"] if host.backup else []
            p.todo.append(Item(host.instance_id, f"{host.instance_id}  {host.name}  {host.ssh_target}  {host.action}",
                               details, value=host))
    return p


def apply(ssh, item, out, backup_check):
    host = item.value
    if not apply_check(backup_check, host):
        raise Failed(f"行わない（{host.reasons[-1]}）")
    result = ssh.run_script(host.ssh_target, remote_file("agent-install.sh"))
    for step in result.steps:
        print(f"      - {step}", file=out)
    v = result.values
    if result.returncode != 0:
        step = result.steps[-1] if result.steps else "（開始前）"
        raise Failed(f"「{step}」で失敗（{result.error_summary()}）")
    active = v.get("agent_active", "")
    if active != "active" and not active.startswith("skipped"):
        raise Failed(f"SSM Agent が動いていない（{active}）")
    diagnostics = v.get("diagnostics_failed", "")
    diagnostics = f"{diagnostics} 件" if diagnostics.isdigit() else diagnostics
    return (f"SSM Agent {v.get('agent_version')}（{'今入れた' if v.get('installed') == 'now' else '入っていた'}）、"
            f"起動時の有効化 {v.get('agent_enabled')}、状態 {active}、診断の失敗 {diagnostics}")


def finish(aws, done, out, wait_seconds, sleep):
    """Online になるのを待つ。ならない台があれば False。"""
    not_online = wait_online(aws, [item.value for item in done], out, wait_seconds, sleep=sleep)
    if not_online:
        print("Online にならないときは、インスタンスプロファイル（AmazonSSMManagedInstanceCore）、"
              "AWS の窓口への送信の 443 番、エージェントのログ（/var/log/amazon/ssm/amazon-ssm-agent.log）を見る", file=out)
    return not not_online


def run(aws, ssh, stdin, out, address="public", use_aws=True, wait_seconds=300,
        assume_yes=False, check_only=False, backup_check=None, confirm_func=confirm, sleep=time.sleep):
    """終了コードを返す（0: すべて成功、1: 失敗・対応できないもの・Online にならないものあり、2: 入力・確認・道具の問題）。"""
    def make_plan(targets):
        p = plan(aws, ssh, targets, out, address, use_aws, backup_check)
        if use_aws:
            p.finish = lambda done, out_: finish(aws, done, out_, wait_seconds, sleep)
        return p

    return execute(stdin, out, make_plan, lambda item: apply(ssh, item, out, backup_check),
                   heading="SSM Agent のインストール・有効化・起動（1 台ずつ順に行う）",
                   assume_yes=assume_yes, check_only=check_only, confirm_func=confirm_func)
