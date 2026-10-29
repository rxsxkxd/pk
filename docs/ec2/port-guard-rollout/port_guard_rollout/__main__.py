"""port-guard-rollout のコマンド。

    python3 -m port_guard_rollout backup --backup-label 2026-10 [--profile P] [--region R] [--check-only] [--yes] < instance-ids.txt
    python3 -m port_guard_rollout install --backup-label 2026-10 [--allow-file allow.txt] [--via ssh|ssm] [SSH のオプション] [--dry-run] [--check-only] [--yes] < instance-ids.txt
    python3 -m port_guard_rollout enable --backup-label 2026-10 [--via ssh|ssm] [SSH のオプション] [--revert-minutes 10] [--port-map 443:8443] [--dry-run] [--check-only] [--yes] < instance-ids.txt
    python3 -m port_guard_rollout ssm-agent --backup-label 2026-10 [SSH のオプション] [--wait-online 秒] [--no-aws] [--check-only] [--yes] < instance-ids.txt
"""

import argparse
import sys
from pathlib import Path

from . import backup, enable, install, ssm_agent
from .awscli import AwsCli
from .backups import make_checker
from .runcommand import RunCommandClient
from .ssh import SshClient


def add_common_arguments(parser):
    parser.add_argument("--profile", help="AWS CLI のプロファイル（省略すると AWS CLI の既定）")
    parser.add_argument("--region", help="リージョン（省略すると AWS CLI の既定）")
    parser.add_argument("--check-only", action="store_true", help="確かめて表示するだけで、変更しない")
    parser.add_argument("--yes", action="store_true", help="試行するかを確かめずに進める")


def add_backup_check_arguments(parser):
    parser.add_argument("--backup-label", metavar="LABEL",
                        help="バックアップ作業のタイミング（backup で指定した値）。この値のタグが付き、作成が終わっていて、"
                             "12 時間以内に作られたバックアップ（AMI）があるインスタンスだけを操作する")
    parser.add_argument("--skip-backup-check", action="store_true",
                        help="バックアップを確かめない（AWS にない手元の再現の環境で試すときだけ使う）")


def backup_checker(parser, args, aws):
    if args.skip_backup_check:
        print("注意: バックアップを確かめない（--skip-backup-check）", file=sys.stderr)
        return None
    if not args.backup_label:
        parser.error("--backup-label が要る（バックアップを確かめるため。手元の再現の環境だけ --skip-backup-check）")
    if not aws.available():
        parser.error("バックアップを確かめるための aws のコマンドが見つからない")
    return make_checker(aws, args.backup_label)


def add_ssh_arguments(parser):
    parser.add_argument("--address", choices=["public", "private"], default="public",
                        help="接続先を引くときに使う IP（既定 public。なければ private）")
    parser.add_argument("--ssh-user", default="centos", help="SSH のユーザー（既定 centos）")
    parser.add_argument("--ssh-key", help="SSH の秘密鍵（省略すると SSH の設定に従う）")
    parser.add_argument("--ssh-option", action="append", default=[], metavar="KEY=VALUE",
                        help="ssh の -o に渡す（何度でも指定できる）")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="port_guard_rollout")
    subparsers = parser.add_subparsers(dest="command", required=True)

    backup_parser = subparsers.add_parser(
        "backup",
        help="インスタンスごとに AMI を作る（再起動しない）。インスタンスの ID を標準入力から 1 行に 1 つ渡す",
    )
    add_common_arguments(backup_parser)
    backup_parser.add_argument("--backup-label", required=True, metavar="LABEL",
                               help="バックアップ作業のタイミング（任意の値。例 2026-10、2026-10-29）。AMI とスナップショットのタグ"
                                    " BackupLabel に付け、ほかの操作の前の確認に使う")

    install_parser = subparsers.add_parser(
        "install",
        help="SSH か SSM の Run Command で、ipset の導入と設定を行う（対象は 80・443 番。遮断はまだ効かせない）。"
             "標準入力に `<インスタンスの ID> [<SSH の接続先>]` を 1 行に 1 台で渡す",
    )
    add_common_arguments(install_parser)
    install_parser.add_argument("--allow-file", type=Path, help="許可する IP の一覧のファイル（1 行 1 件、CIDR 可、# から後はコメント）")
    install_parser.add_argument("--jp-min-entries", type=int, default=1000, help="日本の IP の範囲の最低件数（既定 1000）")
    add_ssh_arguments(install_parser)
    add_backup_check_arguments(install_parser)
    install_parser.add_argument("--via", choices=["ssh", "ssm"], default="ssh",
                                help="実行の手段（既定 ssh。ssm は SSM Agent が動いて Online のインスタンスだけ）")
    install_parser.add_argument("--dry-run", action="store_true",
                                help="確かめて、行う予定の処理と前回の設定から変わることを表示するだけで、変更しない")
    install_parser.add_argument("--script-out", metavar="PATH",
                                help="dry 実行のときに、インスタンスに送る処理をこのファイルに書き出す")
    install_parser.add_argument("--check-in-jp", action="append", default=[], metavar="IP",
                                help="日本の集合に入っているはずの IP（確認用。何度でも指定できる）")
    install_parser.add_argument("--check-outside", action="append", default=[], metavar="IP",
                                help="どちらの集合にも入っていないはずの IP（海外の IP など。何度でも指定できる）")

    ssm_parser = subparsers.add_parser(
        "ssm-agent",
        help="SSH で入り、SSM Agent を入れて有効にし、AWS に登録されたか（Online）を確かめる。"
             "標準入力に `<インスタンスの ID> [<SSH の接続先>]` を 1 行に 1 台で渡す",
    )
    add_common_arguments(ssm_parser)
    add_ssh_arguments(ssm_parser)
    add_backup_check_arguments(ssm_parser)
    ssm_parser.add_argument("--wait-online", type=int, default=300, metavar="SECONDS",
                            help="Online になるのを待つ時間（既定 300 秒）")
    ssm_parser.add_argument("--no-aws", action="store_true",
                            help="AWS を見ない（接続先をすべて書き、登録の状態の確認も行わない。手元の再現の環境で試すとき）")

    enable_parser = subparsers.add_parser(
        "enable",
        help="遮断を有効にする（自動で元に戻る予約を入れてから有効にし、確かめて確定する）。"
             "インスタンスごとに確かめながら 1 台ずつ進める",
    )
    add_common_arguments(enable_parser)
    add_ssh_arguments(enable_parser)
    add_backup_check_arguments(enable_parser)
    enable_parser.add_argument("--via", choices=["ssh", "ssm"], default="ssh", help="実行の手段（既定 ssh）")
    enable_parser.add_argument("--dry-run", action="store_true", help="確かめて、行う予定の処理を表示するだけ")
    enable_parser.add_argument("--revert-minutes", type=int, default=10,
                               help="有効にしてから、確定しなければ自動で元に戻るまでの時間（既定 10 分）")
    enable_parser.add_argument("--port-map", action="append", default=[], metavar="PORT:LOCAL_PORT",
                               help="作業者の PC からつながるかを確かめるときに使うポート（手元の再現の環境のように、"
                                    "転送しているとき。例 443:8443）")
    enable_parser.add_argument("--connect-timeout", type=int, default=5, help="つながるかの確認の待ち時間（秒）")
    enable_parser.add_argument("--probe", action="append", default=[], metavar="PORT:KIND",
                               help="ポートごとの確かめ方（tcp / ssh / http / tls）。既定は 22: ssh、80・8080: http、"
                                    "443・8443: tls、ほか: tcp（何度でも指定できる）")

    args = parser.parse_args(argv)
    aws = AwsCli(profile=args.profile, region=args.region)
    if args.command == "backup":
        return backup.run(aws, sys.stdin, sys.stdout, args.backup_label, assume_yes=args.yes, check_only=args.check_only)
    if args.command == "install":
        allow_text = args.allow_file.read_text(encoding="utf-8") if args.allow_file else "# 許可する IP（なし）\n"
        if args.via == "ssm":
            remote = RunCommandClient(aws)
        else:
            remote = SshClient(user=args.ssh_user, key=args.ssh_key, options=args.ssh_option)
        return install.run(
            aws, remote, sys.stdin, sys.stdout, allow_text=allow_text,
            jp_min_entries=args.jp_min_entries, address=args.address, via=args.via,
            check_in_jp=args.check_in_jp, check_outside=args.check_outside,
            assume_yes=args.yes, check_only=args.check_only, dry_run=args.dry_run, script_out=args.script_out,
            backup_check=backup_checker(install_parser, args, aws),
        )
    if args.command == "enable":
        if args.via == "ssm":
            remote = RunCommandClient(aws)
        else:
            remote = SshClient(user=args.ssh_user, key=args.ssh_key, options=args.ssh_option)
        port_map = dict(item.split(":", 1) for item in args.port_map)
        probes = dict(item.split(":", 1) for item in args.probe)
        bad = [k for k in probes.values() if k not in enable.PROBE_KINDS]
        if bad:
            parser.error(f"--probe の種類は {', '.join(enable.PROBE_KINDS)} のどれか（{', '.join(bad)}）")
        return enable.run(
            aws, remote, sys.stdin, sys.stdout, via=args.via, address=args.address,
            revert_minutes=args.revert_minutes, port_map=port_map, connect_timeout=args.connect_timeout, probes=probes,
            assume_yes=args.yes, check_only=args.check_only, dry_run=args.dry_run,
            backup_check=backup_checker(enable_parser, args, aws),
        )
    if args.command == "ssm-agent":
        ssh = SshClient(user=args.ssh_user, key=args.ssh_key, options=args.ssh_option)
        return ssm_agent.run(
            aws, ssh, sys.stdin, sys.stdout, address=args.address, use_aws=not args.no_aws,
            wait_seconds=args.wait_online, assume_yes=args.yes, check_only=args.check_only,
            backup_check=backup_checker(ssm_parser, args, aws),
        )
    return 2


if __name__ == "__main__":
    sys.exit(main())
