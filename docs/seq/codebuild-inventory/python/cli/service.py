"""CodeBuild プロジェクトの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

import json
import re
from pathlib import Path

from inventory_common import chunked, tags_object, utc_iso

TOOL = "codebuild_inventory.py"
SNAPSHOT_OPTIONS = []
IMAGES = json.loads((Path(__file__).resolve().parent / "codebuild-image-os.json").read_text())


def os_from_image(image):
    """CodeBuild が提供するイメージは名前から OS がわかる。自前のイメージ（ECR など）はわからない。"""
    if image is None:
        return None
    for p in IMAGES:
        if re.search(p["pattern"], image):
            return p["os"]
    return "Unknown" if image.startswith("aws/codebuild/") else "Custom Image"


def snapshot(ctx, opts):
    # プロジェクト名を 100 件ずつまとめて定義を引く
    names = ctx.call("codebuild", "list_projects", {})["projects"]
    for chunk in chunked(names, 100):
        for p in ctx.call("codebuild", "batch_get_projects", {"names": chunk})["projects"]:
            yield project_record(ctx, p)


def project_record(ctx, p):
    env = p.get("environment") or {}
    vpc = p.get("vpcConfig") or {}
    webhook = p.get("webhook")
    logs = p.get("logsConfig") or {}
    return ctx.record("codebuild_project", {
        "project_name": p.get("name"),
        "project_arn": p.get("arn"),
        "description": p.get("description"),
        "environment_type": env.get("type"),
        "image": env.get("image"),
        "base_os": os_from_image(env.get("image")),
        "compute_type": env.get("computeType"),
        "privileged_mode": env.get("privilegedMode"),
        "image_pull_credentials_type": env.get("imagePullCredentialsType"),
        "service_role": p.get("serviceRole"),
        "source_type": (p.get("source") or {}).get("type"),
        "source_location": (p.get("source") or {}).get("location"),
        "source_version": p.get("sourceVersion"),
        "webhook": {
            "build_type": webhook.get("buildType"),
            "filter_group_count": len(webhook.get("filterGroups") or []),
        } if webhook is not None else None,
        "vpc": {
            "vpc_id": vpc["vpcId"],
            "subnets": vpc.get("subnets") or [],
            "security_group_ids": vpc.get("securityGroupIds") or [],
        } if vpc.get("vpcId") else None,
        "timeout_in_minutes": p.get("timeoutInMinutes"),
        "queued_timeout_in_minutes": p.get("queuedTimeoutInMinutes"),
        "concurrent_build_limit": p.get("concurrentBuildLimit"),
        "artifacts_type": (p.get("artifacts") or {}).get("type"),
        "cache_type": (p.get("cache") or {}).get("type"),
        "cloudwatch_logs": (logs.get("cloudWatchLogs") or {}).get("status"),
        "s3_logs": (logs.get("s3Logs") or {}).get("status"),
        "encryption_key": p.get("encryptionKey"),
        "created_at": utc_iso(p.get("created")),
        "last_modified_at": utc_iso(p.get("lastModified")),
        "tags": tags_object(p.get("tags")),
    })


def last_build(ctx, record):
    """直近のビルド。ビルドが 1 度も無ければ None。履歴は 1 ページ目だけを取る。"""
    params = {"projectName": record["project_name"], "sortOrder": "DESCENDING"}
    ids = ctx.call("codebuild", "list_builds_for_project", params, paginate=False).get("ids") or []
    if not ids:
        return None
    b = ctx.call("codebuild", "batch_get_builds", {"ids": ids[:1]})["builds"][0]
    return {
        "build_id": b.get("id"),
        "status": b.get("buildStatus"),
        "current_phase": b.get("currentPhase"),
        "start_time": utc_iso(b.get("startTime")),
        "end_time": utc_iso(b.get("endTime")),
        "source_version": b.get("sourceVersion"),
        "resolved_source_version": b.get("resolvedSourceVersion"),
        "initiator": b.get("initiator"),
    }


DETAIL_KINDS = {
    "last_build": (("codebuild_project",), last_build),
}
