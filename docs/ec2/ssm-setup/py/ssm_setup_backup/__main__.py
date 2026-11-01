"""ssm-setup のバックアップのコマンド（本体の ssm-agent の前に取る）。

    python3 -m ssm_setup_backup backup --backup-label 2026-10 [--profile P] [--region R] [--check-only] [--yes] < instance-ids.txt
    python3 -m ssm_setup_backup check --backup-label 2026-10 [--profile P] [--region R] < instance-ids.txt
"""

import argparse
import sys

from ssm_setup.awscli import AwsCli

from . import backup, check


def add_aws_arguments(parser):
    parser.add_argument("--profile", help="AWS CLI のプロファイル（省略すると AWS CLI の既定）")
    parser.add_argument("--region", help="リージョン（省略すると AWS CLI の既定）")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="ssm_setup_backup")
    subparsers = parser.add_subparsers(dest="command", required=True)

    backup_parser = subparsers.add_parser(
        "backup",
        help="インスタンスごとに AMI を作る（再起動しない）。インスタンスの ID を標準入力から 1 行に 1 つ渡す",
    )
    add_aws_arguments(backup_parser)
    backup_parser.add_argument("--check-only", action="store_true", help="確かめて表示するだけで、変更しない")
    backup_parser.add_argument("--yes", action="store_true", help="試行するかを確かめずに進める")
    backup_parser.add_argument("--backup-label", required=True, metavar="LABEL",
                               help="バックアップ作業のタイミング（任意の値。例 2026-10、2026-10-29）。AMI とスナップショットのタグ"
                                    " BackupLabel に付け、ssm-agent の操作の前の確認に使う")

    check_parser = subparsers.add_parser(
        "check",
        help="バックアップがあるかを確かめるだけ（読み取りだけ）。ssm-agent の操作の前の確認と同じ条件で確かめる。"
             "インスタンスの ID を標準入力から 1 行に 1 つ渡す",
    )
    add_aws_arguments(check_parser)
    check_parser.add_argument("--backup-label", required=True, metavar="LABEL",
                              help="バックアップ作業のタイミング（backup で指定した値）")

    args = parser.parse_args(argv)
    aws = AwsCli(profile=args.profile, region=args.region)
    if args.command == "backup":
        return backup.run(aws, sys.stdin, sys.stdout, args.backup_label, assume_yes=args.yes, check_only=args.check_only)
    if args.command == "check":
        return check.run(aws, sys.stdin, sys.stdout, args.backup_label)
    return 2


if __name__ == "__main__":
    sys.exit(main())
