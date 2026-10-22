#!/usr/bin/env python3
"""EC2 インスタンスごとに 設定 / ベース OS / AMI / SSM の状態 を JSONL で出力する。

API 呼び出しは DescribeInstances と DescribeInstanceInformation（SSM）を 1 回ずつ（ページ分）と、
使われている AMI を 100 個ずつまとめた DescribeImages だけ。出力の項目は ../README.md を参照。
"""

import json
import os
import re
import sys
from datetime import timezone
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

PATTERNS_PATH = Path(__file__).resolve().parent.parent / "ami-os-patterns.json"
# 終了済み（terminated）は除く
LIVE_STATES = ["pending", "running", "stopping", "stopped", "shutting-down"]


def run(ec2, ssm, out, patterns):
    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": LIVE_STATES}]
    )
    instances = [inst for page in pages for res in page["Reservations"] for inst in res["Instances"]]
    images = fetch_images(ec2, sorted({inst["ImageId"] for inst in instances}))
    ssm_by_id, ssm_error = fetch_ssm(ssm)

    for inst in instances:
        rec = record(inst, images.get(inst["ImageId"]), ssm_by_id.get(inst["InstanceId"]), ssm_error, patterns)
        out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def fetch_images(ec2, ids):
    """ID 指定だと 1 つでも登録解除済みの AMI があると全体がエラーになるので、フィルタで引く。"""
    images = {}
    for start in range(0, len(ids), 100):
        pages = ec2.get_paginator("describe_images").paginate(
            IncludeDeprecated=True, Filters=[{"Name": "image-id", "Values": ids[start:start + 100]}]
        )
        for page in pages:
            for image in page["Images"]:
                images[image["ImageId"]] = image
    return images


def fetch_ssm(ssm):
    """SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける。"""
    try:
        pages = ssm.get_paginator("describe_instance_information").paginate()
        return {info["InstanceId"]: info for page in pages for info in page["InstanceInformationList"]}, None
    except ClientError as e:
        err = e.response["Error"]
        return {}, {"operation": "DescribeInstanceInformation", "code": err["Code"], "message": err.get("Message")}


def record(inst, image, ssm, ssm_error, patterns):
    tags = {t["Key"]: t["Value"] for t in inst.get("Tags") or []}
    os_name, os_source = base_os(inst, image, ssm, patterns)
    lt_id = tags.get("aws:ec2launchtemplate:id")
    return {
        "instance_id": inst["InstanceId"],
        "name": tags.get("Name"),
        "state": (inst.get("State") or {}).get("Name"),
        "instance_type": inst.get("InstanceType"),
        "architecture": inst.get("Architecture"),
        "platform_details": inst.get("PlatformDetails"),
        "base_os": os_name,
        "base_os_source": os_source,
        "image_id": inst["ImageId"],
        "image": {
            "name": image.get("Name"),
            "description": image.get("Description"),
            "owner_id": image.get("OwnerId"),
            "creation_date": image.get("CreationDate"),
            "deprecation_time": image.get("DeprecationTime"),
        } if image else None,
        "launch_time": utc_iso(inst.get("LaunchTime")),
        "availability_zone": (inst.get("Placement") or {}).get("AvailabilityZone"),
        "vpc_id": inst.get("VpcId"),
        "subnet_id": inst.get("SubnetId"),
        "private_ip_address": inst.get("PrivateIpAddress"),
        "public_ip_address": inst.get("PublicIpAddress"),
        "security_group_ids": [sg["GroupId"] for sg in inst.get("SecurityGroups") or []],
        "iam_instance_profile_arn": (inst.get("IamInstanceProfile") or {}).get("Arn"),
        "key_name": inst.get("KeyName"),
        "imds_http_tokens": (inst.get("MetadataOptions") or {}).get("HttpTokens"),
        "auto_scaling_group": tags.get("aws:autoscaling:groupName"),
        "launch_template": {"id": lt_id, "version": tags.get("aws:ec2launchtemplate:version")} if lt_id else None,
        "ssm": {
            "ping_status": ssm.get("PingStatus"),
            "agent_version": ssm.get("AgentVersion"),
            "platform_type": ssm.get("PlatformType"),
            "last_ping_at": utc_iso(ssm.get("LastPingDateTime")),
        } if ssm else None,
        "tags": tags,
        "errors": [ssm_error] if ssm_error else [],
    }


def base_os(inst, image, ssm, patterns):
    """SSM エージェントの報告 → AMI 名 → PlatformDetails の順で決める。"""
    ssm_os = " ".join(v for v in [(ssm or {}).get("PlatformName"), (ssm or {}).get("PlatformVersion")] if v)
    if ssm_os:
        return ssm_os, "ssm"
    name = (image or {}).get("Name")
    if name:
        for p in patterns:
            if re.search(p["pattern"], name):
                return p["os"], "ami_name"
    return inst.get("PlatformDetails"), "platform_details"


def utc_iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def main():
    # AWS_REGION は boto3 の版によっては読まれないので明示的に渡す（未設定ならプロファイルの設定に従う）
    session = boto3.Session(region_name=os.environ.get("AWS_REGION"))
    patterns = json.loads(PATTERNS_PATH.read_text())
    run(session.client("ec2"), session.client("ssm"), sys.stdout, patterns)


if __name__ == "__main__":
    main()
