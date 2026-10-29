"""操作の前のバックアップ（AMI）の確認。

backup で作った AMI には、Purpose・SourceInstanceId・BackupLabel（作業者が指定したバックアップ作業のタイミング）のタグが付く。
ssm-agent・install・enable は、インスタンスごとに次の 3 つがそろった AMI があるときだけ操作する。
- BackupLabel のタグが、指定した値と一致する
- 作成が終わっている（State が available。AMI の作成は非同期で進むため）
- 作成の時刻が、確かめた時点から 12 時間以内
"""

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from .awscli import AwsCliError

PURPOSE_TAG = "port-guard-rollout-backup"
LABEL_TAG = "BackupLabel"
MAX_AGE = timedelta(hours=12)


@dataclass
class BackupCheck:
    ok: bool
    image_id: str = ""
    created: str = ""
    reason: str = ""


def parse_time(value):
    """AMI の CreationDate（例 2026-10-29T08:31:29.000Z）を、タイムゾーンつきの日時にする。"""
    return datetime.strptime(value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z")


def find_backup(aws, instance_id, label, now=None, max_age=MAX_AGE):
    """条件に合う AMI を探す。合うものがなければ、理由をつけて返す。"""
    now = now or datetime.now(timezone.utc)
    try:
        response = aws.run(
            "ec2", "describe-images", "--owners", "self",
            "--filters",
            f"Name=tag:Purpose,Values={PURPOSE_TAG}",
            f"Name=tag:SourceInstanceId,Values={instance_id}",
            f"Name=tag:{LABEL_TAG},Values={label}",
        )
    except AwsCliError as error:
        return BackupCheck(False, reason=f"バックアップを確かめられない（{error}）")

    images = sorted(response.get("Images", []) if response else [],
                    key=lambda i: i.get("CreationDate", ""), reverse=True)
    if not images:
        return BackupCheck(False, reason=f"バックアップ作業のタイミング「{label}」のバックアップ（AMI）がない")

    recent = [i for i in images if now - parse_time(i["CreationDate"]) <= max_age]
    if not recent:
        newest = images[0]
        return BackupCheck(False, newest.get("ImageId", ""), newest.get("CreationDate", ""),
                           f"「{label}」のバックアップが 12 時間より前のものしかない（最新 {newest.get('ImageId')}、"
                           f"作成 {newest.get('CreationDate')}）")
    for image in recent:
        if image.get("State") == "available":
            return BackupCheck(True, image.get("ImageId", ""), image.get("CreationDate", ""))
    newest = recent[0]
    state = newest.get("State", "")
    if state == "pending":
        reason = f"バックアップ（{newest.get('ImageId')}）がまだ作成中（pending）"
    else:
        reason = f"バックアップ（{newest.get('ImageId')}）が使えない状態（{state}）"
    return BackupCheck(False, newest.get("ImageId", ""), newest.get("CreationDate", ""), reason)


def make_checker(aws, label, skip=False):
    """操作のコマンドに渡す確認の関数。skip なら None（確かめない。手元の再現の環境で試すときだけ）。"""
    if skip:
        return None
    return lambda instance_id: find_backup(aws, instance_id, label)


def apply_check(checker, host, out=None):
    """host のバックアップを確かめ、なければ host.reasons に理由を入れる。確かめたら host.backup に AMI の ID を入れる。"""
    if checker is None:
        return True
    result = checker(host.instance_id)
    if result.ok:
        host.backup = f"{result.image_id}（{result.created}）"
        return True
    host.reasons.append(result.reason)
    return False
