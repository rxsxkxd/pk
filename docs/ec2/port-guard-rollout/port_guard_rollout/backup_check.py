"""バックアップがあるかを確かめるだけ（読み取りだけ。何も変えない）。

install・enable が操作の前に行う確認（backups.find_backup）と同じ条件で、
インスタンスごとに「操作できる（条件に合うバックアップがある）」と「操作できない（理由つき）」に分けて表示する。
backup で AMI の作成を始めた後、作成が終わったかを確かめるのにも使う。
"""

from datetime import datetime, timezone

from .backups import LABEL_RULE, age_and_remaining, find_backup, valid_label
from .targets import read_targets


def run(aws, stdin, out, label, now=None):
    """終了コードを返す（0: すべての台にバックアップがある、1: ないものがある、2: 入力・道具の問題）。"""
    if not valid_label(label):
        print(f"--backup-label: {LABEL_RULE}", file=out)
        return 2
    if not aws.available():
        print("aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）", file=out)
        return 2

    targets, invalid = read_targets(stdin)  # SSH の接続先が書かれていても、ここでは使わない
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not targets:
        print("インスタンスの ID が 1 つもない（標準入力に 1 行 1 つで渡す）", file=out)
        return 2

    now = now or datetime.now(timezone.utc)
    print(f"{len(targets)} 台のバックアップを確かめる（バックアップ作業のタイミング: {label}。読み取りだけ）", file=out)
    ok, ng = [], []
    for target in targets:
        result = find_backup(aws, target.instance_id, label, now=now)
        (ok if result.ok else ng).append((target.instance_id, result))

    print(f"\n== 操作できる（条件に合うバックアップがある。{len(ok)} 台）", file=out)
    for instance_id, result in ok:
        elapsed, remaining = age_and_remaining(result.created, now=now)
        print(f"  {instance_id}  {result.image_id}  作成 {result.created}（{elapsed:.1f} 時間前。"
              f"期限まであと {remaining:.1f} 時間）", file=out)
    print(f"\n== 操作できない（{len(ng)} 台）", file=out)
    for instance_id, result in ng:
        print(f"  {instance_id}  理由: {result.reason}", file=out)

    print(f"\n== 結果: 操作できる {len(ok)} 台、操作できない {len(ng)} 台", file=out)
    return 1 if ng else 0
