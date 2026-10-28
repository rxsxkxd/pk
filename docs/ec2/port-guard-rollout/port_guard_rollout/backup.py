"""バックアップ: インスタンスごとに AMI を作る（再起動しない）。

流れ:
1. 標準入力からインスタンスの ID の一覧を読む（2 列目に SSH の接続先があっても無視する）
2. 1 台ずつ、バックアップできるかを確かめる（状態、ルートボリュームの種類、AMI を作る権限）
3. バックアップできるものと、できないもの（理由つき）を分けて表示する
4. バックアップできるものについて、試行するかを確かめる
5. 1 台ずつ順に AMI を作る（`create-image --no-reboot`。完了は待たない）
"""

import json
import re
from dataclasses import dataclass, field
from datetime import datetime

from .awscli import AwsCliError
from .console import confirm
from .targets import read_targets

# AMI を作れるインスタンスの状態（止まっていても作れる）
BACKUP_STATES = {"running", "stopped"}

# AMI の名前に使う文字（それ以外の文字の並びは 1 つの "-" に置き換える。空白も置き換える）と、名前の長さの上限
_AMI_NAME_DISALLOWED = re.compile(r"[^A-Za-z0-9()\[\]./'@_-]+")
AMI_NAME_MAX_LENGTH = 128

PURPOSE_TAG = "port-guard-rollout-backup"


@dataclass
class Candidate:
    """バックアップの対象のインスタンスと、確かめた結果。"""

    instance_id: str
    name: str = ""
    state: str = ""
    instance_type: str = ""
    availability_zone: str = ""
    volume_count: int = 0
    reasons: list = field(default_factory=list)

    @property
    def backupable(self):
        return not self.reasons


@dataclass
class Result:
    instance_id: str
    image_id: str = ""
    image_name: str = ""
    error: str = ""


def inspect(aws, instance_id):
    """インスタンスを 1 台確かめ、バックアップできない理由があれば reasons に入れる。"""
    candidate = Candidate(instance_id)
    try:
        response = aws.run("ec2", "describe-instances", "--instance-ids", instance_id)
    except AwsCliError as error:
        if error.code in ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed"):
            candidate.reasons.append("インスタンスが見つからない")
        else:
            candidate.reasons.append(f"情報を取れない（{error}）")
        return candidate

    instances = [i for r in response.get("Reservations", []) for i in r.get("Instances", [])]
    if not instances:
        candidate.reasons.append("インスタンスが見つからない")
        return candidate
    instance = instances[0]

    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
    candidate.name = tags.get("Name", "")
    candidate.state = instance.get("State", {}).get("Name", "")
    candidate.instance_type = instance.get("InstanceType", "")
    candidate.availability_zone = instance.get("Placement", {}).get("AvailabilityZone", "")
    candidate.volume_count = len(instance.get("BlockDeviceMappings", []))

    if candidate.state not in BACKUP_STATES:
        candidate.reasons.append(f"状態が {candidate.state}（running か stopped のときだけ作れる）")
    if instance.get("RootDeviceType") != "ebs":
        candidate.reasons.append(f"ルートボリュームが EBS ではない（{instance.get('RootDeviceType')}）")
    if candidate.backupable:
        reason = check_permission(aws, instance_id)
        if reason:
            candidate.reasons.append(reason)
    return candidate


def check_permission(aws, instance_id):
    """AMI を作る権限があるかを、実際には作らない試行（--dry-run）で確かめる。問題がなければ None。"""
    try:
        aws.run(
            "ec2", "create-image", "--instance-id", instance_id,
            "--name", "port-guard-rollout-dry-run", "--no-reboot", "--dry-run",
        )
    except AwsCliError as error:
        if error.code == "DryRunOperation":
            return None
        if error.code == "UnauthorizedOperation":
            return "AMI を作る権限がない（ec2:CreateImage）"
        return f"AMI を作れるかを確かめられない（{error}）"
    return None


def image_name(candidate, run_id):
    """AMI の名前: <Name タグ>-<インスタンスの ID>-before-port-guard-<実行の ID>。

    使えない文字は "-" に置き換え、長すぎるときは先頭（Name タグの側）を削る。
    """
    label = _AMI_NAME_DISALLOWED.sub("-", candidate.name).strip("-")
    name = "-".join(p for p in [label, candidate.instance_id, "before-port-guard", run_id] if p)
    return name[-AMI_NAME_MAX_LENGTH:].lstrip("-")


def create_backup(aws, candidate, run_id):
    name = image_name(candidate, run_id)
    tags = [
        {"Key": "Name", "Value": name},
        {"Key": "Purpose", "Value": PURPOSE_TAG},
        {"Key": "SourceInstanceId", "Value": candidate.instance_id},
        {"Key": "SourceInstanceName", "Value": candidate.name},
        {"Key": "BackupRunId", "Value": run_id},
    ]
    tag_specifications = [
        {"ResourceType": "image", "Tags": tags},
        {"ResourceType": "snapshot", "Tags": tags},
    ]
    try:
        response = aws.run(
            "ec2", "create-image",
            "--instance-id", candidate.instance_id,
            # 値が "-" で始まってもオプションと取り違えないよう、"--名前=値" の形で渡す
            f"--name={name}",
            f"--description=Backup of {candidate.instance_id} before port guard (run {run_id})",
            "--no-reboot",
            f"--tag-specifications={json.dumps(tag_specifications, ensure_ascii=False)}",
        )
    except AwsCliError as error:
        return Result(candidate.instance_id, image_name=name, error=str(error))
    return Result(candidate.instance_id, image_id=response.get("ImageId", ""), image_name=name)


def print_candidates(candidates, out):
    ok = [c for c in candidates if c.backupable]
    ng = [c for c in candidates if not c.backupable]

    print(f"\n== バックアップできるインスタンス（{len(ok)} 台）", file=out)
    for c in ok:
        print(f"  {c.instance_id}  {c.name or '(Name なし)'}  {c.state}  {c.instance_type}  "
              f"{c.availability_zone}  ボリューム {c.volume_count} 個", file=out)
    print(f"\n== バックアップできないインスタンス（{len(ng)} 台）", file=out)
    for c in ng:
        print(f"  {c.instance_id}  {c.name or ''}  理由: {' / '.join(c.reasons)}", file=out)
    return ok


def run(aws, stdin, out, assume_yes=False, check_only=False, confirm_func=confirm, now=None):
    """バックアップの流れ全体。終了コードを返す（0: すべて成功、1: 失敗あり、2: 入力・確認の問題）。"""
    if not aws.available():
        print("aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）", file=out)
        return 2

    targets, invalid = read_targets(stdin)
    ids = [t.instance_id for t in targets]  # SSH の接続先が書かれていても、バックアップでは使わない
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not ids:
        print("インスタンスの ID が 1 つもない（標準入力に 1 行 1 つで渡す）", file=out)
        return 2

    print(f"{len(ids)} 台を確かめる", file=out)
    candidates = []
    for instance_id in ids:
        print(f"  確認中: {instance_id}", file=out)
        candidates.append(inspect(aws, instance_id))

    ok = print_candidates(candidates, out)
    if check_only:
        return 0
    if not ok:
        print("\nバックアップできるインスタンスがないので、終わる", file=out)
        return 1 if len(ok) < len(candidates) else 0

    if not assume_yes:
        answer = confirm_func(
            f"\n上の {len(ok)} 台のバックアップ（AMI の作成。再起動しない）を試行しますか？ [y/N]: ")
        if answer is None:
            print("確認のための端末がない。確かめずに進めるなら --yes を付ける", file=out)
            return 2
        if not answer:
            print("中止した", file=out)
            return 0

    run_id = (now or datetime.now()).strftime("%Y%m%d-%H%M%S")
    print(f"\n== バックアップ（実行の ID: {run_id}。1 台ずつ順に行う）", file=out)
    results = []
    for index, candidate in enumerate(ok, start=1):
        result = create_backup(aws, candidate, run_id)
        results.append(result)
        if result.error:
            print(f"  [{index}/{len(ok)}] 失敗  {candidate.instance_id}  {result.error}", file=out)
        else:
            print(f"  [{index}/{len(ok)}] 開始  {candidate.instance_id} → {result.image_id}  ({result.image_name})", file=out)

    succeeded = [r for r in results if not r.error]
    failed = [r for r in results if r.error]
    print(f"\n== 結果: 開始 {len(succeeded)} 台、失敗 {len(failed)} 台、対象外 {len(candidates) - len(ok)} 台", file=out)
    if succeeded:
        image_ids = " ".join(r.image_id for r in succeeded)
        print("AMI の作成は完了を待っていない（取り始めた時点の中身が残る）。進み具合は次で確かめる:", file=out)
        print(f"  aws ec2 describe-images --image-ids {image_ids} "
              "--query 'Images[].[ImageId,State,Name]' --output table", file=out)
    return 1 if failed or len(ok) < len(candidates) else 0
