"""バックアップ: インスタンスごとに AMI を作る（再起動しない）。

確かめる（plan）: 1 台ずつ、バックアップできるかを確かめる（状態、ルートボリュームの種類、AMI を作る権限）。
  2 列目に SSH の接続先があっても使わない
行う（apply）: 1 台ずつ順に AMI を作る（`create-image --no-reboot`。完了は待たない）

入力・表示・確認・失敗の扱いは ssm_setup.flow の共通の流れ。
"""

import json
import re
from dataclasses import dataclass, field
from datetime import datetime

from ssm_setup.awscli import AwsCliError
from ssm_setup.console import confirm
from ssm_setup.flow import Item, Plan, execute, require, require_aws

from .backups import LABEL_RULE, LABEL_TAG, PURPOSE_TAG, valid_label

# AMI を作れるインスタンスの状態（止まっていても作れる）
BACKUP_STATES = {"running", "stopped"}

# AMI の名前に使う文字（それ以外の文字の並びは 1 つの "-" に置き換える。空白も置き換える）と、名前の長さの上限
_AMI_NAME_DISALLOWED = re.compile(r"[^A-Za-z0-9()\[\]./'@_-]+")
AMI_NAME_MAX_LENGTH = 128


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
    image_id: str = ""  # 作り始めた AMI の ID

    @property
    def backupable(self):
        return not self.reasons


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
            "--name", "ssm-setup-dry-run", "--no-reboot", "--dry-run",
        )
    except AwsCliError as error:
        if error.code == "DryRunOperation":
            return None
        if error.code == "UnauthorizedOperation":
            return "AMI を作る権限がない（ec2:CreateImage）"
        return f"AMI を作れるかを確かめられない（{error}）"
    return None


def image_name(candidate, run_id):
    """AMI の名前: <Name タグ>-<インスタンスの ID>-before-ssm-setup-<実行の ID>。

    使えない文字は "-" に置き換え、長すぎるときは先頭（Name タグの側）を削る。
    """
    label = _AMI_NAME_DISALLOWED.sub("-", candidate.name).strip("-")
    name = "-".join(p for p in [label, candidate.instance_id, "before-ssm-setup", run_id] if p)
    return name[-AMI_NAME_MAX_LENGTH:].lstrip("-")


def create_backup(aws, candidate, run_id, label):
    """AMI の作成を始める。戻り値は (AMI の ID, AMI の名前)。失敗は AwsCliError。"""
    name = image_name(candidate, run_id)
    tags = [
        {"Key": "Name", "Value": name},
        {"Key": "Purpose", "Value": PURPOSE_TAG},
        {"Key": "SourceInstanceId", "Value": candidate.instance_id},
        {"Key": "SourceInstanceName", "Value": candidate.name},
        {"Key": "BackupRunId", "Value": run_id},
        {"Key": LABEL_TAG, "Value": label},
    ]
    tag_specifications = [
        {"ResourceType": "image", "Tags": tags},
        {"ResourceType": "snapshot", "Tags": tags},
    ]
    response = aws.run(
        "ec2", "create-image",
        "--instance-id", candidate.instance_id,
        # 値が "-" で始まってもオプションと取り違えないよう、"--名前=値" の形で渡す
        f"--name={name}",
        f"--description=Backup of {candidate.instance_id} before ssm-setup (label {label}, run {run_id})",
        "--no-reboot",
        f"--tag-specifications={json.dumps(tag_specifications, ensure_ascii=False)}",
    )
    return response.get("ImageId", ""), name


def plan(aws, targets, label, run_id):
    require(valid_label(label), f"--backup-label: {LABEL_RULE}")
    require_aws(aws)
    p = Plan(title="バックアップできる", question="バックアップ（AMI の作成。再起動しない）を試行しますか？",
             keep_title=None, excluded_title="バックアップできない", done_word="開始", finish=finish)
    for target in targets:  # SSH の接続先が書かれていても、バックアップでは使わない
        c = inspect(aws, target.instance_id)
        if c.backupable:
            p.todo.append(Item(c.instance_id, f"{c.instance_id}  {c.name or '(Name なし)'}  {c.state}  {c.instance_type}  "
                                              f"{c.availability_zone}  ボリューム {c.volume_count} 個", value=c))
        else:
            p.excluded.append(f"{c.instance_id}  {c.name}  理由: {' / '.join(c.reasons)}")
    return p


def finish(done, out):
    image_ids = " ".join(item.value.image_id for item in done)
    print("AMI の作成は完了を待っていない（取り始めた時点の中身が残る）。ほかの操作は、作成が終わって（available）から、"
          "12 時間以内に、同じ --backup-label を指定して行う。進み具合は次で確かめる:", file=out)
    print(f"  aws ec2 describe-images --image-ids {image_ids} "
          "--query 'Images[].[ImageId,State,Name]' --output table", file=out)


def run(aws, stdin, out, label, assume_yes=False, check_only=False, confirm_func=confirm, now=None):
    """終了コードを返す（0: すべて開始、1: 失敗・対象外あり、2: 入力・確認の問題）。"""
    run_id = (now or datetime.now()).strftime("%Y%m%d-%H%M%S")

    def apply(item):
        item.value.image_id, name = create_backup(aws, item.value, run_id, label)
        return f"{item.value.image_id}（{name}）"

    return execute(stdin, out, lambda targets: plan(aws, targets, label, run_id), apply,
                   heading=f"バックアップ（バックアップ作業のタイミング: {label}、実行の ID: {run_id}。1 台ずつ順に行う。"
                           "すでにバックアップがあっても、新しく作る）",
                   assume_yes=assume_yes, check_only=check_only, confirm_func=confirm_func)
