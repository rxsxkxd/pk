"""EC2 インスタンスの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

import json
import re
from pathlib import Path

from aws_client import AwsError
from inventory_common import chunked, error_entry, tags_object, utc_iso

TOOL = "ec2_inventory.py"
SNAPSHOT_OPTIONS = [("--filter", "DescribeInstances のフィルタ。AWS CLI と同じ書き方（例: Name=tag:env,Values=prod）")]
# 終了済み（terminated）は除く
LIVE_STATES = ["pending", "running", "stopping", "stopped", "shutting-down"]
PATTERNS = json.loads((Path(__file__).resolve().parent / "ami-os-patterns.json").read_text())


def parse_filter(text):
    m = re.fullmatch(r"Name=([^,]+),Values=(.+)", text)
    if not m:
        raise SystemExit(f"--filter の形が違います: {text}")
    return {"Name": m[1], "Values": m[2].split(",")}


def snapshot(ctx, opts):
    filters = [{"Name": "instance-state-name", "Values": LIVE_STATES}] + [parse_filter(f) for f in opts["filter"]]
    reservations = ctx.call("ec2", "describe_instances", {"Filters": filters})["Reservations"]
    instances = [inst for r in reservations for inst in r["Instances"]]

    # AMI は ID 指定だと 1 つでも登録解除済みのものがあると全体がエラーになるので、フィルタで 100 個ずつ引く
    images = {}
    for chunk in chunked(sorted({inst["ImageId"] for inst in instances}), 100):
        params = {"IncludeDeprecated": True, "Filters": [{"Name": "image-id", "Values": chunk}]}
        for image in ctx.call("ec2", "describe_images", params)["Images"]:
            images[image["ImageId"]] = image

    # SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
    ssm_by_id, ssm_errors = {}, []
    try:
        infos = ctx.call("ssm", "describe_instance_information", {})["InstanceInformationList"]
        ssm_by_id = {info["InstanceId"]: info for info in infos}
    except AwsError as e:
        ssm_errors = [error_entry(e)]

    for inst in instances:
        yield instance_record(ctx, inst, images.get(inst["ImageId"]), ssm_by_id.get(inst["InstanceId"]), ssm_errors)


def instance_record(ctx, inst, image, ssm, errors):
    tags = tags_object(inst.get("Tags"))
    os_name, os_source = base_os(inst, image, ssm)
    lt_id = tags.get("aws:ec2launchtemplate:id")
    return ctx.record("ec2_instance", {
        "instance_id": inst["InstanceId"],
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
        "monitoring_state": (inst.get("Monitoring") or {}).get("State"),
        "auto_scaling_group": tags.get("aws:autoscaling:groupName"),
        "launch_template": {"id": lt_id, "version": tags.get("aws:ec2launchtemplate:version")} if lt_id else None,
        "ssm": {
            "ping_status": ssm.get("PingStatus"),
            "agent_version": ssm.get("AgentVersion"),
            "platform_type": ssm.get("PlatformType"),
            "last_ping_at": utc_iso(ssm.get("LastPingDateTime")),
        } if ssm else None,
        "tags": {k: v for k, v in tags.items() if k != "Name"},
    }, errors)


def base_os(inst, image, ssm):
    """SSM エージェントの報告 → AMI 名 → PlatformDetails の順で決める。"""
    ssm_os = " ".join(v for v in [(ssm or {}).get("PlatformName"), (ssm or {}).get("PlatformVersion")] if v)
    if ssm_os:
        return ssm_os, "ssm"
    name = (image or {}).get("Name")
    if name:
        for p in PATTERNS:
            if re.search(p["pattern"], name):
                return p["os"], "ami_name"
    return inst.get("PlatformDetails"), "platform_details"


def volumes(ctx, record):
    """インスタンスに付いている EBS ボリューム。"""
    iid = record["instance_id"]
    params = {"Filters": [{"Name": "attachment.instance-id", "Values": [iid]}]}
    result = []
    for v in ctx.call("ec2", "describe_volumes", params)["Volumes"]:
        a = next((a for a in v.get("Attachments") or [] if a.get("InstanceId") == iid), {})
        result.append({
            "volume_id": v.get("VolumeId"),
            "device": a.get("Device"),
            "size_gib": v.get("Size"),
            "volume_type": v.get("VolumeType"),
            "iops": v.get("Iops"),
            "throughput": v.get("Throughput"),
            "encrypted": v.get("Encrypted"),
            "kms_key_id": v.get("KmsKeyId"),
            "delete_on_termination": a.get("DeleteOnTermination"),
            "state": v.get("State"),
        })
    return result


def target_health(ctx, record):
    """どのターゲットグループに登録されているかはわからないので、すべてのターゲットグループを見る（実行ごとに 1 回）。"""
    groups = ctx.cached("target_groups", lambda: [
        g["TargetGroupArn"] for g in ctx.call("elbv2", "describe_target_groups", {})["TargetGroups"]
    ])
    result = []
    for tg in groups:
        descriptions = ctx.cached(("health", tg), lambda tg=tg: ctx.call(
            "elbv2", "describe_target_health", {"TargetGroupArn": tg})["TargetHealthDescriptions"])
        for d in descriptions:
            if d["Target"]["Id"] == record["instance_id"]:
                health = d.get("TargetHealth") or {}
                result.append({"target_group_arn": tg, "port": d["Target"].get("Port"),
                               "state": health.get("State"), "reason": health.get("Reason")})
    return result


DETAIL_KINDS = {
    "volumes": (("ec2_instance",), volumes),
    "target_health": (("ec2_instance",), target_health),
}
