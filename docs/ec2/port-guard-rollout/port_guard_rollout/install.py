"""ipset の導入と設定（遮断はまだ効かせない）。

流れ（バックアップと同じ形）:
1. 標準入力から対象のインスタンスを読む（`<インスタンスの ID> [<SSH の接続先>]`）
2. 実行の手段ごとに、相手を決める
   - SSH: 接続先が書かれていなければ、AWS CLI でインスタンスの IP を引く
   - SSM: SSM に登録されている（Online）ことを確かめる（2 列目の接続先は使わない）
3. 1 台ずつ今の状態を確かめ（読み取りだけ）、入れられるものと入れられないもの（理由つき）を分けて表示する。
   前回の設定があれば、何が変わるか（ポート、許可する IP の増減）も表示する
4. dry 実行なら、行う予定の処理を表示して終わる（変更はしない）
5. 入れられるものについて、試行するかを確かめる
6. 1 台ずつ順に、ipset と python3 を入れ、設定・スクリプト・systemd のユニットを置き、
   日本の IP の範囲を取って集合を作り、確かめる。ユニットは enable せず、INPUT からの参照も足さない
"""

import base64
import shlex
from dataclasses import dataclass, field
from pathlib import Path

from .backups import apply_check
from .console import confirm
from .targets import read_targets, resolve_ssh_target

REMOTE_DIR = Path(__file__).parent / "remote"

VIA_LABELS = {"ssh": "SSH", "ssm": "SSM の Run Command"}

# 絞るポート（HTTP と HTTPS だけ。SSH の 22 番は、ほかのシステムからの接続がありうるので対象にしない）
TARGET_PORTS = "80,443"

# SSM の Run Command で送る処理の大きさの目安（これを超えたら知らせる。上限の正確な値は未確認）
SSM_SCRIPT_WARN_BYTES = 48_000


@dataclass
class Host:
    instance_id: str
    ssh_target: str = ""
    name: str = ""
    state: dict = field(default_factory=dict)  # 今の状態（check.sh の結果）
    reasons: list = field(default_factory=list)  # 入れられない理由
    notes: list = field(default_factory=list)  # 入れられるが知らせておくこと
    changes: list = field(default_factory=list)  # 前回の設定から変わること
    backup: str = ""  # 確かめたバックアップ（AMI の ID と作成の時刻）

    @property
    def installable(self):
        return not self.reasons


def remote_file(name):
    return (REMOTE_DIR / name).read_text(encoding="utf-8")


def _b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def build_install_script(ports, allow_text, jp_min_entries, check_in_jp=(), check_outside=()):
    """install.sh の前に、渡す値（PG_*）を置いたシェルの処理を作る。"""
    values = {
        "PG_PORTS": ports,
        "PG_JP_MIN_ENTRIES": str(jp_min_entries),
        "PG_ALLOW_B64": _b64(allow_text),
        "PG_APPLY_B64": _b64(remote_file("port-guard-apply")),
        "PG_UPDATE_JP_B64": _b64(remote_file("port-guard-update-jp")),
        "PG_SERVICE_B64": _b64(remote_file("port-guard.service")),
        "PG_CHECK_IN_JP": " ".join(check_in_jp),
        "PG_CHECK_OUTSIDE": " ".join(check_outside),
    }
    prelude = "".join(f"{key}={shlex.quote(value)}\n" for key, value in values.items())
    return prelude + remote_file("install.sh")


def allow_entries(text):
    """許可する IP の一覧のファイルの中身から、項目（各行の最初の語）を取り出す。"""
    entries = []
    for line in text.splitlines():
        fields = line.split("#", 1)[0].split()
        if fields:
            entries.append(fields[0])
    return entries


def classify(host, result):
    """check.sh の結果から、入れられない理由と、知らせておくことを決める。"""
    if result.connection_failed:
        host.reasons.append(f"接続できない（{result.error_summary(1)}）")
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
    if s.get("firewalld_active") == "active":
        host.reasons.append("firewalld が動いている")
    elif s.get("firewalld_enabled") == "enabled":
        host.reasons.append("firewalld が起動時に有効になっている（次の再起動で動き出す）")
    if s.get("iptables_enabled") == "enabled":
        host.reasons.append("iptables のサービスが起動時に有効になっている")
    if s.get("port_guard_jump", "0") != "0":
        host.reasons.append("port-guard の遮断がすでに有効になっている")
    if s.get("iptables_other_rules", "0") != "0":
        host.reasons.append(f"既存の iptables のルールがある（{s['iptables_other_rules']} 件）")
    other_sets = [n for n in s.get("ipset_sets", "").split(",") if n and not n.startswith("port_guard_")]
    if other_sets:
        host.reasons.append(f"既存の ipset の集合がある（{', '.join(other_sets)}）")

    if s.get("port_guard_installed") == "yes":
        host.notes.append("port-guard のファイルがすでにある（上書きする）")
    if s.get("systemd") != "running":
        host.notes.append("systemd が動いていない（ユニットの登録を飛ばす）")
    if s.get("docker_active") == "active":
        host.notes.append("Docker が動いている（iptables のルールを入れる）")


def describe_changes(host, ports, new_allow):
    """前回置いた設定（ポートと許可する IP）から、何が変わるかを host.changes に入れる。"""
    s = host.state
    if "ports_current" in s and s["ports_current"] != ports:
        host.changes.append(f"ポート {s['ports_current']} → {ports}")
    if "allow_current" in s:
        current = [e for e in s["allow_current"].split(",") if e]
        added = [e for e in new_allow if e not in current]
        removed = [e for e in current if e not in new_allow]
        if added:
            host.changes.append(f"許可する IP を足す: {', '.join(added)}")
        if removed:
            host.changes.append(f"許可する IP を消す: {', '.join(removed)}")


def target_of(host, via):
    return host.ssh_target if via == "ssh" else host.instance_id


def print_hosts(hosts, out, via):
    ok = [h for h in hosts if h.installable]
    ng = [h for h in hosts if not h.installable]
    print(f"\n== 入れられるインスタンス（{len(ok)} 台）", file=out)
    for h in ok:
        notes = f"  注意: {' / '.join(h.notes)}" if h.notes else ""
        print(f"  {h.instance_id}  {h.name or ''}  {target_of(h, via)}  {h.state.get('os', '')}{notes}", file=out)
        if h.backup:
            print(f"      バックアップ: {h.backup}", file=out)
        if h.changes:
            print(f"      前回の設定から変わること: {' / '.join(h.changes)}", file=out)
    print(f"\n== 入れられないインスタンス（{len(ng)} 台）", file=out)
    for h in ng:
        print(f"  {h.instance_id}  {h.name or ''}  {target_of(h, via)}  理由: {' / '.join(h.reasons)}", file=out)
    return ok


def print_plan(out, ports, allow, jp_min_entries, script, via, script_out):
    print("\n== dry 実行: 入れられるインスタンスに、次の処理を行う予定（変更はしていない）", file=out)
    print("  1. yum install ipset python3", file=out)
    print(f"  2. /etc/port-guard/port-guard.conf を置く（PORT_GUARD_PORTS={ports}、JP_MIN_ENTRIES={jp_min_entries}）", file=out)
    print(f"  3. /etc/port-guard/allow.txt を置く（{len(allow)} 件: {', '.join(allow) or 'なし'}）", file=out)
    print("  4. /usr/local/sbin/port-guard-apply、port-guard-update-jp、/etc/systemd/system/port-guard.service を置く"
          "（systemd が動いていれば daemon-reload。enable はしない）", file=out)
    print("  5. port-guard-update-jp で日本の IP の範囲を取り、集合を作る（遮断のルールは入れない）", file=out)
    size = len(script.encode("utf-8"))
    print(f"  送る処理の大きさ: {size} バイト", file=out)
    if via == "ssm" and len(_b64(script)) > SSM_SCRIPT_WARN_BYTES:
        print("  注意: SSM の Run Command で送るには大きい可能性がある（上限は未確認）", file=out)
    if script_out:
        Path(script_out).write_text(script, encoding="utf-8")
        print(f"  送る処理を {script_out} に書き出した", file=out)


def evaluate(result, check_in_jp, check_outside):
    """install.sh の結果から、問題の一覧を作る（空なら成功）。"""
    v = result.values
    problems = []
    if result.returncode != 0:
        step = result.steps[-1] if result.steps else "（開始前）"
        return [f"「{step}」で失敗（{result.error_summary()}）"]
    if v.get("port_guard_jump", "0") != "0":
        problems.append("遮断が有効になっている（この段階では有効にしない）")
    if v.get("port_guard_unit_enabled") == "enabled":
        problems.append("port-guard のユニットが起動時に有効になっている")
    if v.get("ipset_unit_enabled") == "enabled":
        problems.append("ipset のサービスが起動時に有効になっている")
    for ip in check_in_jp:
        if v.get(f"check_in_jp_{ip}") != "yes":
            problems.append(f"{ip} が日本の集合に入っていない")
    for ip in check_outside:
        if v.get(f"check_outside_{ip}") != "jp=no,allow=no":
            problems.append(f"{ip} が集合に入っている（{v.get(f'check_outside_{ip}')}）")
    return problems


def run(aws, remote, stdin, out, ports=TARGET_PORTS, allow_text="", jp_min_entries=1000, address="public", via="ssh",
        check_in_jp=(), check_outside=(), assume_yes=False, check_only=False, dry_run=False, script_out=None,
        backup_check=None, confirm_func=confirm):
    """終了コードを返す（0: すべて成功、1: 失敗または対象外あり、2: 入力・確認・道具の問題）。

    remote は、via が "ssh" なら SshClient、"ssm" なら RunCommandClient。
    """
    if not remote.available():
        print("ssh のコマンドが見つからない" if via == "ssh" else "aws のコマンドが見つからない", file=out)
        return 2

    targets, invalid = read_targets(stdin)
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not targets:
        print("対象がない（標準入力に `<インスタンスの ID> [<SSH の接続先>]` を 1 行に 1 台で渡す）", file=out)
        return 2
    if via == "ssh" and any(not t.ssh_target for t in targets) and not aws.available():
        print("接続先を引くための aws のコマンドが見つからない（AWS CLI を入れるか、接続先を書く）", file=out)
        return 2
    if via == "ssm" and any(t.ssh_target for t in targets):
        print("SSM で実行するので、2 列目の SSH の接続先は使わない", file=out)

    new_allow = allow_entries(allow_text)
    print(f"{len(targets)} 台を確かめる（{VIA_LABELS[via]} で、今の状態を読むだけ）", file=out)
    hosts = []
    check_script = remote_file("check.sh")
    for target in targets:
        host = Host(target.instance_id, target.ssh_target if via == "ssh" else "")
        apply_check(backup_check, host)
        if host.installable and via == "ssh":
            resolve_ssh_target(aws, host, address)
        elif host.installable:
            ping = remote.ping_status(host.instance_id)
            if ping != "Online":
                host.reasons.append(f"SSM で操作できない（{ping}）")
        if host.installable:
            print(f"  確認中: {host.instance_id}  {target_of(host, via)}", file=out)
            classify(host, remote.run_script(target_of(host, via), check_script, timeout=120))
            if host.installable:
                describe_changes(host, ports, new_allow)
        hosts.append(host)

    ok = print_hosts(hosts, out, via)
    if check_only:
        return 0
    script = build_install_script(ports, allow_text, jp_min_entries, check_in_jp, check_outside)
    if dry_run:
        print_plan(out, ports, new_allow, jp_min_entries, script, via, script_out)
        return 0
    if not ok:
        print("\n入れられるインスタンスがないので、終わる", file=out)
        return 1

    if not assume_yes:
        answer = confirm_func(
            f"\n上の {len(ok)} 台に、ipset の導入と設定（ポート {ports}。遮断はまだ効かせない）を"
            f"{VIA_LABELS[via]} で試行しますか？ [y/N]: ")
        if answer is None:
            print("確認のための端末がない。確かめずに進めるなら --yes を付ける", file=out)
            return 2
        if not answer:
            print("中止した", file=out)
            return 0

    print(f"\n== ipset の導入と設定（{VIA_LABELS[via]} で、1 台ずつ順に行う）", file=out)
    failed = 0
    for index, host in enumerate(ok, start=1):
        print(f"  [{index}/{len(ok)}] {host.instance_id}  {target_of(host, via)}", file=out)
        if not apply_check(backup_check, host):
            failed += 1
            print(f"      行わない: {host.reasons[-1]}", file=out)
            continue
        result = remote.run_script(target_of(host, via), script)
        for step in result.steps:
            print(f"      - {step}", file=out)
        problems = evaluate(result, check_in_jp, check_outside)
        if problems:
            failed += 1
            print(f"      失敗: {' / '.join(problems)}", file=out)
        else:
            v = result.values
            print(f"      完了: 日本の範囲 {v.get('jp_entries')} 件、許可する IP {v.get('allow_entries')} 件、"
                  f"ユニット {v.get('unit')}（enable はしていない）、遮断はまだ効いていない", file=out)

    print(f"\n== 結果: 完了 {len(ok) - failed} 台、失敗 {failed} 台、対象外 {len(hosts) - len(ok)} 台", file=out)
    if failed < len(ok):
        print("集合の中身（日本の IP の範囲と許可する IP）は今回の実行の時点のもの。このあと遮断を有効にすると、"
              "この時点の一覧がそのまま使われる（新しくするには、有効にする前にもう一度 install を実行する）", file=out)
    return 1 if failed or len(ok) < len(hosts) else 0
