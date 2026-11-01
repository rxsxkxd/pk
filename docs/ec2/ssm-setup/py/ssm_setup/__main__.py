"""ssm-setup のコマンド（SSM の有効化）。

    python3 -m ssm_setup ssm-role [--instance-profile port-guard-ssm] [--check-only] [--yes] < instance-ids.txt
    python3 -m ssm_setup ssm-check [--ok-out enabled.txt] [--ng-out ng.txt] [--profile P] [--region R] < instance-ids.txt
    python3 -m ssm_setup ssm-connect-check [--via session|run-command] [--connect-timeout 秒] [--ok-out ok.txt] [--ng-out connect-ng.txt] [--profile P] [--region R] < enabled.txt
    python3 -m ssm_setup ssm-agent --backup-label 2026-10 [SSH のオプション] [--wait-online 秒] [--no-aws] [--check-only] [--yes] < instance-ids.txt
"""

import argparse
import sys

from ssm_setup_backup.backups import make_checker

from . import ssm_agent, ssm_check, ssm_connect_check, ssm_role
from .awscli import AwsCli
from .runcommand import RunCommandClient
from .ssh import SshClient


def add_common_arguments(parser):
    parser.add_argument("--profile", help="AWS CLI のプロファイル（省略すると AWS CLI の既定）")
    parser.add_argument("--region", help="リージョン（省略すると AWS CLI の既定）")
    parser.add_argument("--check-only", action="store_true", help="確かめて表示するだけで、変更しない")
    parser.add_argument("--yes", action="store_true", help="試行するかを確かめずに進める")


def add_backup_check_arguments(parser):
    parser.add_argument("--backup-label", metavar="LABEL",
                        help="バックアップ作業のタイミング（ssm_setup_backup の backup で指定した値）。この値のタグが付き、作成が終わっていて、"
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
    parser = argparse.ArgumentParser(prog="ssm_setup")
    subparsers = parser.add_subparsers(dest="command", required=True)

    role_parser = subparsers.add_parser(
        "ssm-role",
        help="IAM ロールが未設定のインスタンスに、SSM 用のインスタンスプロファイルを関連付ける（すでにロールがある台には何もしない）。"
             "インスタンスの ID を標準入力から 1 行に 1 つ渡す",
    )
    add_common_arguments(role_parser)
    role_parser.add_argument("--instance-profile", default=ssm_role.DEFAULT_PROFILE,
                             help=f"関連付けるインスタンスプロファイル（既定 {ssm_role.DEFAULT_PROFILE}。先に作っておく）")

    ssm_check_parser = subparsers.add_parser(
        "ssm-check",
        help="SSM が使える状態かを、権限と AWS の上の状態だけで確かめる（インスタンスプロファイル、"
             "AmazonSSMManagedInstanceCore、Online）。インスタンスには何も送らない。"
             "インスタンスの ID を標準入力から 1 行に 1 つ渡す",
    )
    ssm_check_parser.add_argument("--profile", help="AWS CLI のプロファイル（省略すると AWS CLI の既定）")
    ssm_check_parser.add_argument("--region", help="リージョン（省略すると AWS CLI の既定）")
    ssm_check_parser.add_argument("--ok-out", metavar="PATH",
                                  help="「SSM 有効」の台のインスタンスの ID を、このファイルに 1 行に 1 つ書き出す"
                                       "（ssm-connect-check の標準入力に渡す）")
    ssm_check_parser.add_argument("--ng-out", metavar="PATH",
                                  help="「SSM Agent で直す」台のインスタンスの ID を、このファイルに 1 行に 1 つ書き出す"
                                       "（ssm_setup_backup の backup と ssm-agent の標準入力に渡せる。「手で直す」台は行の先頭を # にして残す）")

    connect_parser = subparsers.add_parser(
        "ssm-connect-check",
        help="SSM で実際に入れるかを、echo を 1 回だけ流して確かめる（事前の確認はしない。設定は変えない）。"
             "ssm-check の --ok-out の一覧を標準入力に渡す",
    )
    connect_parser.add_argument("--profile", help="AWS CLI のプロファイル（省略すると AWS CLI の既定）")
    connect_parser.add_argument("--region", help="リージョン（省略すると AWS CLI の既定）")
    connect_parser.add_argument("--via", choices=ssm_connect_check.VIA_CHOICES, default="session",
                                help="接続の確かめ方（既定 session = Session Manager。session-manager-plugin が要る。"
                                     "run-command = Run Command）")
    connect_parser.add_argument("--connect-timeout", type=int, default=60, metavar="SECONDS",
                                help="1 台の接続の確認の待ち時間（既定 60 秒）")
    connect_parser.add_argument("--ok-out", metavar="PATH",
                                help="入れた台のインスタンスの ID を、このファイルに 1 行に 1 つ書き出す"
                                     "（フェーズ 2 の port-guard-rollout の標準入力に渡せる）")
    connect_parser.add_argument("--ng-out", metavar="PATH",
                                help="入れなかった台のインスタンスの ID を、理由と一緒にこのファイルに書き出す"
                                     "（直した後に、もう一度渡せる）")

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

    args = parser.parse_args(argv)
    aws = AwsCli(profile=args.profile, region=args.region)
    if args.command == "ssm-role":
        return ssm_role.run(aws, sys.stdin, sys.stdout, profile_name=args.instance_profile,
                            assume_yes=args.yes, check_only=args.check_only)
    if args.command == "ssm-check":
        return ssm_check.run(aws, sys.stdin, sys.stdout, ok_out=args.ok_out, ng_out=args.ng_out)
    if args.command == "ssm-connect-check":
        return ssm_connect_check.run(aws, RunCommandClient(aws), sys.stdin, sys.stdout, via=args.via,
                                     timeout=args.connect_timeout, ok_out=args.ok_out, ng_out=args.ng_out)
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
