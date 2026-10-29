"""SSM Agent のインストールと有効化（設計の「SSM の準備」）。

流れ（バックアップ・install と同じ形）:
1. 標準入力から対象のインスタンスを読む（`<インスタンスの ID> [<SSH の接続先>]`）
2. SSH の接続先を決める（書かれていなければ、AWS CLI でインスタンスの IP を引く）
3. 1 台ずつ、SSH で入って SSM Agent の状態を確かめ（読み取りだけ）、AWS の側の登録の状態も見て、
   行うこと（インストール・有効化・起動し直し・何もしない）と、対応できないもの（理由つき）を分けて表示する
4. 試行するかを確かめる
5. 1 台ずつ順に、SSM Agent を入れて、起動時に有効にして起動し直す
6. AWS の側で登録されたか（`Online`）を、決めた時間まで待って確かめる

インスタンスプロファイルや IAM の権限の付与は行わない（別の作業）。
権限のないインスタンスは、入れても `Online` にならないことを表示する。
"""

import time
from dataclasses import dataclass, field

from .awscli import AwsCliError
from .backups import apply_check
from .console import confirm
from .install import remote_file
from .targets import read_targets, resolve_ssh_target

INSTALL = "インストール"
ENABLE = "有効化と起動"
RESTART = "起動し直し"


@dataclass
class Host:
    instance_id: str
    ssh_target: str = ""
    name: str = ""
    state: dict = field(default_factory=dict)  # 今の状態（ssm-check.sh の結果）
    ping_status: str = ""  # AWS の側の登録の状態（Online / ConnectionLost / 未登録。AWS を見ないときは空）
    action: str = ""  # 行うこと（空なら何もしない）
    reasons: list = field(default_factory=list)  # 対応できない理由
    notes: list = field(default_factory=list)  # 知らせておくこと
    backup: str = ""  # 確かめたバックアップ（AMI の ID と作成の時刻）


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
    """ssm-check.sh の結果と登録の状態から、行うことと、対応できない理由を決める。"""
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


def print_hosts(hosts, out):
    todo = [h for h in hosts if h.action]
    ready = [h for h in hosts if not h.action and not h.reasons]
    ng = [h for h in hosts if h.reasons]

    print(f"\n== 行うこと（{len(todo)} 台）", file=out)
    for h in todo:
        version = h.state.get("agent_version") or "なし"
        notes = f"  注意: {' / '.join(h.notes)}" if h.notes else ""
        print(f"  {h.instance_id}  {h.name}  {h.ssh_target}  {h.action}"
              f"（今の SSM Agent: {version}、登録: {h.ping_status or '見ていない'}）{notes}", file=out)
        if h.backup:
            print(f"      バックアップ: {h.backup}", file=out)
    print(f"\n== 何もしない（すでに使える。{len(ready)} 台）", file=out)
    for h in ready:
        print(f"  {h.instance_id}  {h.name}  {h.ssh_target}  登録: {h.ping_status or '見ていない'}", file=out)
    print(f"\n== 対応できない（{len(ng)} 台）", file=out)
    for h in ng:
        print(f"  {h.instance_id}  {h.name}  {h.ssh_target}  理由: {' / '.join(h.reasons)}", file=out)
    return todo


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


def run(aws, ssh, stdin, out, address="public", use_aws=True, wait_seconds=300,
        assume_yes=False, check_only=False, backup_check=None, confirm_func=confirm, sleep=time.sleep):
    """終了コードを返す（0: すべて成功、1: 失敗・対応できないもの・Online にならないものあり、2: 入力・確認・道具の問題）。"""
    if not ssh.available():
        print("ssh のコマンドが見つからない", file=out)
        return 2

    targets, invalid = read_targets(stdin)
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not targets:
        print("対象がない（標準入力に `<インスタンスの ID> [<SSH の接続先>]` を 1 行に 1 台で渡す）", file=out)
        return 2
    if not use_aws and any(not t.ssh_target for t in targets):
        print("--no-aws のときは、すべての行に SSH の接続先を書く", file=out)
        return 2
    if use_aws and not aws.available():
        print("aws のコマンドが見つからない（AWS CLI を入れるか、--no-aws を付けて接続先を書く）", file=out)
        return 2

    print(f"{len(targets)} 台を確かめる（SSH で入って、SSM Agent の状態を読むだけ）", file=out)
    hosts = []
    check_script = remote_file("ssm-check.sh")
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
        hosts.append(host)

    todo = print_hosts(hosts, out)
    excluded = len([h for h in hosts if h.reasons])
    if check_only:
        return 0
    if not todo:
        print("\n行うことがないので、終わる", file=out)
        return 1 if excluded else 0

    if not assume_yes:
        answer = confirm_func(f"\n上の {len(todo)} 台に、SSM Agent のインストール・有効化・起動を試行しますか？ [y/N]: ")
        if answer is None:
            print("確認のための端末がない。確かめずに進めるなら --yes を付ける", file=out)
            return 2
        if not answer:
            print("中止した", file=out)
            return 0

    install_script = remote_file("ssm-install.sh")
    print("\n== SSM Agent のインストール・有効化・起動（1 台ずつ順に行う）", file=out)
    done, failed = [], 0
    for index, host in enumerate(todo, start=1):
        print(f"  [{index}/{len(todo)}] {host.instance_id}  {host.ssh_target}  {host.action}", file=out)
        if not apply_check(backup_check, host):
            failed += 1
            print(f"      行わない: {host.reasons[-1]}", file=out)
            continue
        result = ssh.run_script(host.ssh_target, install_script)
        for step in result.steps:
            print(f"      - {step}", file=out)
        v = result.values
        if result.returncode != 0:
            failed += 1
            step = result.steps[-1] if result.steps else "（開始前）"
            print(f"      失敗: 「{step}」で失敗（{result.error_summary()}）", file=out)
            continue
        active = v.get("agent_active", "")
        if active not in ("active",) and not active.startswith("skipped"):
            failed += 1
            print(f"      失敗: SSM Agent が動いていない（{active}）", file=out)
            continue
        done.append(host)
        diagnostics = v.get("diagnostics_failed", "")
        diagnostics = f"{diagnostics} 件" if diagnostics.isdigit() else diagnostics
        print(f"      完了: SSM Agent {v.get('agent_version')}（{'今入れた' if v.get('installed') == 'now' else '入っていた'}）、"
              f"起動時の有効化 {v.get('agent_enabled')}、状態 {active}、診断の失敗 {diagnostics}", file=out)

    not_online = []
    if use_aws and done:
        not_online = wait_online(aws, done, out, wait_seconds, sleep=sleep)
        if not_online:
            print("Online にならないときは、インスタンスプロファイル（AmazonSSMManagedInstanceCore）、"
                  "AWS の窓口への送信の 443 番、エージェントのログ（/var/log/amazon/ssm/amazon-ssm-agent.log）を見る", file=out)

    print(f"\n== 結果: 完了 {len(done)} 台（うち Online にならなかった {len(not_online)} 台）、"
          f"失敗 {failed} 台、対応できない {excluded} 台", file=out)
    return 1 if failed or excluded or not_online else 0
