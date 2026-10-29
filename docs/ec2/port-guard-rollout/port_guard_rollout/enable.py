"""遮断の有効化（設計のチェックポイント 3）。

流れ:
1. 標準入力から対象のインスタンスを読む（`<インスタンスの ID> [<SSH の接続先>]`）
2. 全台を確かめ（読み取りだけ）、有効にできるものとできないもの（理由つき）を分けて表示する
3. 有効にできるものを 1 台ずつ、**インスタンスごとのチェックポイント**で進める
   - その台の内容を表示し、有効化するかを確かめる（y: 進める、n: 飛ばす、q: 残りを止める）
   - 決めた時間の後に自動で元に戻る予約を入れてから、有効にする
   - 確かめる: インスタンスに引き続き入れるか（SSH または SSM）、作業者の PC（日本）から対象のポートにつながるか
   - すべて合格なら予約を取り消して確定する。不合格ならすぐに元に戻す。インスタンスに入れなくなったら、予約で自動的に戻る

ポートはインスタンスの設定（install で置いた /etc/port-guard/port-guard.conf）から読み、80・443 番（--include-ssh で
入れたときは 22・80・443 番）であることを確かめる。22 番は既定では対象にしない（外部からの SSH はセキュリティグループで弾く前提）。
"""

import shlex
import socket
import ssl
from dataclasses import dataclass, field
from datetime import datetime

from .backups import apply_check
from .console import ask
from .install import ALLOWED_PORT_SETS, SSH_CAUTION, VIA_LABELS, classify, remote_file
from .targets import read_targets, resolve_ssh_target

PROCEED, SKIP, QUIT = "y", "n", "q"


@dataclass
class Host:
    instance_id: str
    ssh_target: str = ""
    name: str = ""
    state: dict = field(default_factory=dict)
    reasons: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    backup: str = ""  # 確かめたバックアップ（AMI の ID と作成の時刻）

    @property
    def enableable(self):
        return not self.reasons

    @property
    def ports(self):
        return [p for p in self.state.get("ports_current", "").split(",") if p]


def connect_host(host):
    """作業者の PC からつなぐときの相手（SSH の接続先から、ユーザーとポートを外したもの）。"""
    target = host.ssh_target.split("@", 1)[-1]
    return target.split(":", 1)[0]


# ポートごとの確かめ方の既定。TCP の接続だけでは、途中の転送や代理の仕組みが接続を受け付けてしまい、
# 遮断されていても「つながる」と誤って判定することがあるので、相手が実際に応答するところまで確かめる
DEFAULT_PROBES = {"22": "ssh", "80": "http", "8080": "http", "443": "tls", "8443": "tls"}
PROBE_KINDS = ("tcp", "ssh", "http", "tls")


def can_connect(address, port, timeout, kind="tcp"):
    """作業者の PC から相手に届き、相手が応答するか。kind: tcp（接続だけ）/ ssh / http / tls。"""
    try:
        with socket.create_connection((address, port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            if kind == "ssh":
                return sock.recv(4).startswith(b"SSH-")
            if kind == "http":
                sock.sendall(f"HEAD / HTTP/1.0\r\nHost: {address}\r\n\r\n".encode("ascii"))
                return sock.recv(5).startswith(b"HTTP/")
            if kind == "tls":
                context = ssl.create_default_context()
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE  # 証明書ではなく、相手が応答するかだけを見る
                with context.wrap_socket(sock, server_hostname=address):
                    return True
            return True
    except (OSError, ssl.SSLError):
        return False


def classify_for_enable(host, result):
    """install と同じ確認に加えて、有効にできる状態か（install が済んでいるか、一覧があるか）を見る。"""
    classify(host, result)
    host.notes = [n for n in host.notes if "上書きする" not in n]  # install 向けの注意は外す
    if host.reasons and any("すでに有効" in r for r in host.reasons):
        host.reasons = ["遮断がすでに有効になっている"]
        return
    if not host.state:
        return
    s = host.state
    if s.get("port_guard_installed") != "yes":
        host.reasons.append("port-guard が入っていない（先に install を行う）")
        return
    if not host.ports:
        host.reasons.append("対象のポートの設定がない（先に install を行う）")
    elif ",".join(host.ports) not in ALLOWED_PORT_SETS:
        host.reasons.append(f"ポートの設定が {' か '.join(ALLOWED_PORT_SETS)} ではない（{','.join(host.ports)}。install をやり直す）")
    elif "22" in host.ports:
        host.notes.append("22 番（SSH）も対象")
    jp_min = int(s.get("jp_min_entries", "1000") or 1000)
    jp_file = int(s.get("jp_file_entries", "0") or 0)
    if jp_file < jp_min:
        host.reasons.append(f"日本の IP の範囲の一覧が少ない（{jp_file} 件。最低 {jp_min} 件）")
    if s.get("revert_pending"):
        host.notes.append(f"前の自動で元に戻る予約が残っている（{s['revert_pending']}）")
    if s.get("jp_set_entries", "") in ("", "0"):
        host.notes.append("集合がない（再起動などで消えた。有効化のときに一覧のファイルから作り直す）")


def print_hosts(hosts, out):
    ok = [h for h in hosts if h.enableable]
    ng = [h for h in hosts if not h.enableable]
    print(f"\n== 有効にできるインスタンス（{len(ok)} 台）", file=out)
    for h in ok:
        s = h.state
        notes = f"  注意: {' / '.join(h.notes)}" if h.notes else ""
        print(f"  {h.instance_id}  {h.name}  {h.ssh_target or ''}  ポート {','.join(h.ports)}  "
              f"日本の範囲 {s.get('jp_file_entries')} 件  許可する IP {len([e for e in s.get('allow_current', '').split(',') if e])} 件"
              f"{notes}", file=out)
        if h.backup:
            print(f"      バックアップ: {h.backup}", file=out)
    print(f"\n== 有効にできないインスタンス（{len(ng)} 台）", file=out)
    for h in ng:
        print(f"  {h.instance_id}  {h.name}  {h.ssh_target or ''}  理由: {' / '.join(h.reasons)}", file=out)
    return ok


def prelude(**values):
    return "".join(f"PG_{key.upper()}={shlex.quote(str(value))}\n" for key, value in values.items())


def enable_one(host, remote, via, out, run_id, revert_minutes, port_map, connect_timeout, connect, probes):
    """1 台を有効にして確かめる。戻り値は "確定" / "戻した" / "失敗"。"""
    target = host.ssh_target if via == "ssh" else host.instance_id
    result = remote.run_script(target, prelude(run_id=run_id, revert_minutes=revert_minutes)
                               + remote_file("enable-apply.sh"))
    for step in result.steps:
        print(f"      - {step}", file=out)
    revert = result.values.get("revert", "")
    if result.returncode != 0 or result.values.get("jump", "0") == "0":
        step = result.steps[-1] if result.steps else "（開始前）"
        print(f"      有効化に失敗（「{step}」。{result.error_summary()}）。元に戻す", file=out)
        remote.run_script(target, prelude(revert=revert) + remote_file("enable-revert.sh"))
        return "失敗"
    print(f"      有効化した（ポート {result.values.get('ports')}、日本の範囲 {result.values.get('jp_set_entries')} 件、"
          f"許可する IP {result.values.get('allow_set_entries')} 件、ユニット {result.values.get('unit')}）", file=out)

    # 確かめる
    problems = []
    reach = remote.run_script(target, "printf 'PG reachable=yes\\n'", timeout=60)
    if reach.values.get("reachable") != "yes":
        print(f"      インスタンスに入れなくなった（{reach.error_summary(1)}）。"
              f"{revert_minutes} 分後に予約で自動的に元に戻る（{revert}）", file=out)
        return "失敗"
    print(f"      確認: {VIA_LABELS[via]} で引き続き入れる", file=out)
    address = connect_host(host)
    for port in host.ports:
        local_port = port_map.get(port, port)
        kind = probes.get(port) or DEFAULT_PROBES.get(port, "tcp")
        weak = "。TCP の接続だけの弱い確認（--probe で種類を指定できる）" if kind == "tcp" else ""
        if connect(address, int(local_port), connect_timeout, kind):
            print(f"      確認: 作業者の PC から {address}:{local_port}（ポート {port}）に {kind} で応答がある{weak}", file=out)
        else:
            problems.append(f"作業者の PC から {address}:{local_port}（ポート {port}）に {kind} で応答がない")

    if problems:
        print(f"      不合格: {' / '.join(problems)}。すぐに元に戻す", file=out)
        back = remote.run_script(target, prelude(revert=revert) + remote_file("enable-revert.sh"))
        print(f"      元に戻した（遮断のルール {back.values.get('jump', '?')} 件）", file=out)
        return "戻した"
    done = remote.run_script(target, prelude(revert=revert) + remote_file("enable-confirm.sh"))
    if done.returncode != 0 or done.values.get("revert_alive") == "yes":
        print(f"      予約の取り消しに失敗（{done.error_summary()}）。{revert_minutes} 分後に自動的に元に戻る", file=out)
        return "失敗"
    print(f"      確定（自動で元に戻る予約を取り消した: {revert}）", file=out)
    return "確定"


def run(aws, remote, stdin, out, via="ssh", address="public", revert_minutes=10, port_map=None,
        connect_timeout=5, probes=None, assume_yes=False, check_only=False, dry_run=False, backup_check=None,
        ask_func=ask, connect=can_connect, now=None):
    """終了コードを返す（0: すべて確定、1: 戻した・失敗・飛ばした・対象外あり、2: 入力・確認・道具の問題）。"""
    port_map = port_map or {}
    probes = probes or {}
    if not remote.available():
        print("ssh のコマンドが見つからない" if via == "ssh" else "aws のコマンドが見つからない", file=out)
        return 2
    targets, invalid = read_targets(stdin)
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not targets:
        print("対象がない（標準入力に `<インスタンスの ID> [<SSH の接続先>]` を 1 行に 1 台で渡す）", file=out)
        return 2
    if any(not t.ssh_target for t in targets) and not aws.available():
        print("接続先を引くための aws のコマンドが見つからない（AWS CLI を入れるか、接続先を書く）", file=out)
        return 2

    print(f"{len(targets)} 台を確かめる（{VIA_LABELS[via]} で、今の状態を読むだけ）", file=out)
    hosts = []
    check_script = remote_file("check.sh") + remote_file("enable-check.sh")
    for t in targets:
        host = Host(t.instance_id, t.ssh_target)
        apply_check(backup_check, host)
        if host.enableable:
            resolve_ssh_target(aws, host, address)  # SSM のときも、つながるかの確認に IP を使う
        if host.enableable and via == "ssm":
            ping = remote.ping_status(host.instance_id)
            if ping != "Online":
                host.reasons.append(f"SSM で操作できない（{ping}）")
        if host.enableable:
            target = host.ssh_target if via == "ssh" else host.instance_id
            print(f"  確認中: {host.instance_id}  {target}", file=out)
            classify_for_enable(host, remote.run_script(target, check_script, timeout=120))
        hosts.append(host)

    ok = print_hosts(hosts, out)
    if check_only:
        return 0
    if dry_run:
        print(f"\n== dry 実行: 有効にできるインスタンスに、1 台ずつ次の処理を行う予定（変更はしていない）", file=out)
        print("  1. 今の iptables のルールを /var/lib/port-guard/ に控える", file=out)
        print(f"  2. {revert_minutes} 分後に遮断のルールを消す予約を入れる（systemd-run。systemd がなければ切り離したプロセス）", file=out)
        print("  3. systemctl enable --now port-guard（systemd がなければ port-guard-apply を直接実行）", file=out)
        print(f"  4. 確かめる: {VIA_LABELS[via]} で入れるか、作業者の PC から対象のポートに届いて相手が応答するか"
              f"（22: SSH の応答、80・8080: HTTP の応答、443・8443: TLS の接続、ほか: TCP の接続）", file=out)
        print("  5. 合格なら予約を取り消して確定、不合格ならすぐに元に戻す", file=out)
        return 0
    if not ok:
        print("\n有効にできるインスタンスがないので、終わる", file=out)
        return 1

    if any("22" in h.ports for h in ok):
        print(f"\n注意: {SSH_CAUTION}", file=out)
    run_id = (now or datetime.now()).strftime("%Y%m%d-%H%M%S")
    print(f"\n== 遮断の有効化（{VIA_LABELS[via]} で、1 台ずつ。インスタンスごとに確かめる。実行の ID: {run_id}）", file=out)
    results = {}
    for index, host in enumerate(ok, start=1):
        target = host.ssh_target if via == "ssh" else host.instance_id
        print(f"\n  [{index}/{len(ok)}] {host.instance_id}  {host.name}  {target}  ポート {','.join(host.ports)}", file=out)
        if not assume_yes:
            answer = ask_func(f"  この台の遮断を有効にしますか？（{revert_minutes} 分後に自動で元に戻る予約を入れてから行う） "
                              "[y: 進める / n: 飛ばす / q: 残りを止める]: ", (PROCEED, SKIP, QUIT))
            if answer is None:
                print("確認のための端末がない。確かめずに進めるなら --yes を付ける", file=out)
                return 2
            if answer == QUIT:
                print("  残りを止めた", file=out)
                break
            if answer == SKIP:
                results[host.instance_id] = "飛ばした"
                print("  飛ばした", file=out)
                continue
        if not apply_check(backup_check, host):
            results[host.instance_id] = "失敗"
            print(f"  行わない: {host.reasons[-1]}", file=out)
            continue
        results[host.instance_id] = enable_one(host, remote, via, out, run_id, revert_minutes, port_map,
                                               connect_timeout, connect, probes)

    counts = {k: list(results.values()).count(k) for k in ("確定", "戻した", "失敗", "飛ばした")}
    untouched = len(ok) - len(results)
    print(f"\n== 結果: 確定 {counts['確定']} 台、戻した {counts['戻した']} 台、失敗 {counts['失敗']} 台、"
          f"飛ばした {counts['飛ばした']} 台、止めたので行わなかった {untouched} 台、対象外 {len(hosts) - len(ok)} 台", file=out)
    if counts["確定"]:
        print("集合の中身（日本の IP の範囲と許可する IP）は、install を実行した時点のもの", file=out)
    return 0 if counts["確定"] == len(hosts) else 1
