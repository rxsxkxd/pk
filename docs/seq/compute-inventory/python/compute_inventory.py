#!/usr/bin/env python3
"""EC2 と ECS をまとめて棚卸しする。

  snapshot: まとめて取得できる API だけで一覧を取り、1 件 1 行の JSONL で出す
  detail:   標準入力のレコード（snapshot の出力を jq で絞ったもの）に、リソースごとの詳細を足す

使い方と出力の項目は ../README.md を参照。
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

PATTERNS_PATH = Path(__file__).resolve().parent.parent / "ami-os-patterns.json"
CODEBUILD_IMAGES_PATH = Path(__file__).resolve().parent.parent / "codebuild-image-os.json"
# 終了済み（terminated）は除く
LIVE_STATES = ["pending", "running", "stopping", "stopped", "shutting-down"]
# 混み合っているときは SDK が自分で間隔を空ける
CLIENT_CONFIG = Config(retries={"mode": "adaptive"})
DETAIL_KINDS = ["task_definition", "tasks", "target_health"]


def session():
    # AWS_REGION は boto3 の版によっては読まれないので明示的に渡す（未設定ならプロファイルの設定に従う）
    return boto3.Session(region_name=os.environ.get("AWS_REGION"))


def write(out, rec):
    out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def error_entry(error):
    err = error.response["Error"]
    return {"operation": error.operation_name, "code": err["Code"], "message": err.get("Message")}


def utc_iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def now_iso():
    return utc_iso(datetime.now(timezone.utc))


def cluster_name(arn):
    return arn.split("/")[-1]


def chunked(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def paginate(client, operation, key, **params):
    return [item for page in client.get_paginator(operation).paginate(**params) for item in page[key]]


# ------------------------------------------------------------ snapshot


class Snapshot:
    def __init__(self, ec2_filters, clusters):
        s = session()
        self.ec2 = s.client("ec2", config=CLIENT_CONFIG)
        self.ssm = s.client("ssm", config=CLIENT_CONFIG)
        self.ecs = s.client("ecs", config=CLIENT_CONFIG)
        self.codebuild = s.client("codebuild", config=CLIENT_CONFIG)
        self.region = s.region_name
        self.ec2_filters = ec2_filters
        self.clusters = clusters
        self.patterns = json.loads(PATTERNS_PATH.read_text())
        self.codebuild_images = json.loads(CODEBUILD_IMAGES_PATH.read_text())

    def run(self, out):
        self.common = {"region": self.region, "collected_at": now_iso()}

        clusters = self.clusters or paginate(self.ecs, "list_clusters", "clusterArns")
        services = [s for c in clusters for s in self.describe_services(c)]
        container_instances = {
            ci["ec2InstanceId"]: (c, ci) for c in clusters for ci in self.describe_container_instances(c)
        }

        pages = self.ec2.get_paginator("describe_instances").paginate(
            Filters=[{"Name": "instance-state-name", "Values": LIVE_STATES}] + self.ec2_filters
        )
        reservations = [r for page in pages for r in page["Reservations"]]
        images = self.fetch_images(sorted({i["ImageId"] for r in reservations for i in r["Instances"]}))
        ssm_by_id, ssm_error = self.fetch_ssm()

        for r in reservations:
            for inst in r["Instances"]:
                write(out, self.ec2_record(
                    r["OwnerId"], inst, images.get(inst["ImageId"]), ssm_by_id.get(inst["InstanceId"]),
                    ssm_error, container_instances.get(inst["InstanceId"]),
                ))
        for service in services:
            write(out, self.service_record(service))
        for project in self.fetch_projects():
            write(out, self.project_record(project))

    def describe_services(self, cluster):
        arns = paginate(self.ecs, "list_services", "serviceArns", cluster=cluster)
        return [
            s for chunk in chunked(arns, 10)
            for s in self.ecs.describe_services(cluster=cluster, services=chunk)["services"]
        ]

    def describe_container_instances(self, cluster):
        """コンテナインスタンスの応答にはクラスターが入っていないので、呼び出し側でクラスターと組にする。"""
        arns = paginate(self.ecs, "list_container_instances", "containerInstanceArns", cluster=cluster)
        return [
            ci for chunk in chunked(arns, 100)
            for ci in self.ecs.describe_container_instances(cluster=cluster, containerInstances=chunk)["containerInstances"]
        ]

    def fetch_images(self, ids):
        """ID 指定だと 1 つでも登録解除済みの AMI があると全体がエラーになるので、フィルタで引く。"""
        images = {}
        for chunk in chunked(ids, 100):
            pages = self.ec2.get_paginator("describe_images").paginate(
                IncludeDeprecated=True, Filters=[{"Name": "image-id", "Values": chunk}]
            )
            for page in pages:
                for image in page["Images"]:
                    images[image["ImageId"]] = image
        return images

    def fetch_ssm(self):
        """SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける。"""
        try:
            infos = paginate(self.ssm, "describe_instance_information", "InstanceInformationList")
            return {info["InstanceId"]: info for info in infos}, None
        except ClientError as e:
            return {}, error_entry(e)

    def ec2_record(self, account_id, inst, image, ssm, ssm_error, container_instance):
        tags = {t["Key"]: t["Value"] for t in inst.get("Tags") or [] if t["Key"] != "Name"}
        os_name, os_source = self.base_os(inst, image, ssm)
        cluster, ci = container_instance or (None, None)
        return {
            "record_type": "ec2_instance",
            "account_id": account_id,
            **self.common,
            "instance_id": inst["InstanceId"],
            "state": (inst.get("State") or {}).get("Name"),
            "instance_type": inst.get("InstanceType"),
            "architecture": inst.get("Architecture"),
            "base_os": os_name,
            "base_os_source": os_source,
            "image_id": inst["ImageId"],
            "launch_time": utc_iso(inst.get("LaunchTime")),
            "tags": tags,
            "ecs": {
                "cluster_name": cluster_name(cluster),
                "container_instance_arn": ci.get("containerInstanceArn"),
                "status": ci.get("status"),
                "agent_connected": ci.get("agentConnected"),
                "agent_version": (ci.get("versionInfo") or {}).get("agentVersion"),
            } if ci else None,
            "errors": [ssm_error] if ssm_error else [],
        }

    def base_os(self, inst, image, ssm):
        """SSM エージェントの報告 → AMI 名 → PlatformDetails の順で決める。"""
        ssm_os = " ".join(v for v in [(ssm or {}).get("PlatformName"), (ssm or {}).get("PlatformVersion")] if v)
        if ssm_os:
            return ssm_os, "ssm"
        name = (image or {}).get("Name")
        if name:
            for p in self.patterns:
                if re.search(p["pattern"], name):
                    return p["os"], "ami_name"
        return inst.get("PlatformDetails"), "platform_details"

    def service_record(self, service):
        return {
            "record_type": "ecs_service",
            "account_id": service["serviceArn"].split(":")[4],
            **self.common,
            "cluster_name": cluster_name(service["clusterArn"]),
            "service_name": service.get("serviceName"),
            "service_arn": service["serviceArn"],
            "status": service.get("status"),
            "launch_type": service.get("launchType"),
            "desired_count": service.get("desiredCount"),
            "running_count": service.get("runningCount"),
            "task_definition": service.get("taskDefinition"),
            "load_balancers": [
                {
                    "target_group_arn": lb.get("targetGroupArn"),
                    "container_name": lb.get("containerName"),
                    "container_port": lb.get("containerPort"),
                }
                for lb in service.get("loadBalancers") or []
            ],
            "errors": [],
        }

    def fetch_projects(self):
        """プロジェクト名を 100 件ずつまとめて定義を引く。"""
        names = paginate(self.codebuild, "list_projects", "projects")
        return [
            p for chunk in chunked(names, 100)
            for p in self.codebuild.batch_get_projects(names=chunk)["projects"]
        ]

    def project_record(self, project):
        env = project.get("environment") or {}
        vpc = project.get("vpcConfig") or {}
        webhook = project.get("webhook")
        logs = project.get("logsConfig") or {}
        return {
            "record_type": "codebuild_project",
            "account_id": project["arn"].split(":")[4],
            **self.common,
            "project_name": project.get("name"),
            "project_arn": project["arn"],
            "description": project.get("description"),
            "environment_type": env.get("type"),
            "image": env.get("image"),
            "base_os": self.codebuild_os(env.get("image")),
            "compute_type": env.get("computeType"),
            "privileged_mode": env.get("privilegedMode"),
            "image_pull_credentials_type": env.get("imagePullCredentialsType"),
            "service_role": project.get("serviceRole"),
            "source_type": (project.get("source") or {}).get("type"),
            "source_location": (project.get("source") or {}).get("location"),
            "source_version": project.get("sourceVersion"),
            "webhook": {
                "build_type": webhook.get("buildType"),
                "filter_group_count": len(webhook.get("filterGroups") or []),
            } if webhook is not None else None,
            "vpc": {
                "vpc_id": vpc["vpcId"],
                "subnets": vpc.get("subnets") or [],
                "security_group_ids": vpc.get("securityGroupIds") or [],
            } if vpc.get("vpcId") else None,
            "timeout_in_minutes": project.get("timeoutInMinutes"),
            "queued_timeout_in_minutes": project.get("queuedTimeoutInMinutes"),
            "concurrent_build_limit": project.get("concurrentBuildLimit"),
            "artifacts_type": (project.get("artifacts") or {}).get("type"),
            "cache_type": (project.get("cache") or {}).get("type"),
            "cloudwatch_logs": (logs.get("cloudWatchLogs") or {}).get("status"),
            "s3_logs": (logs.get("s3Logs") or {}).get("status"),
            "encryption_key": project.get("encryptionKey"),
            "created_at": utc_iso(project.get("created")),
            "last_modified_at": utc_iso(project.get("lastModified")),
            "tags": {t["key"]: t.get("value") for t in project.get("tags") or []},
            "errors": [],
        }

    def codebuild_os(self, image):
        """CodeBuild が提供するイメージは名前から OS がわかる。自前のイメージ（ECR など）はわからない。"""
        if image is None:
            return None
        for p in self.codebuild_images:
            if re.search(p["pattern"], image):
                return p["os"]
        return "Unknown" if image.startswith("aws/codebuild/") else "Custom Image"


# ------------------------------------------------------------ detail


class Detail:
    APPLIES_TO = {
        "task_definition": {"ecs_service"},
        "tasks": {"ecs_service"},
        "target_health": {"ecs_service", "ec2_instance"},
    }

    def __init__(self, kinds, interval):
        s = session()
        self.ecs = s.client("ecs", config=CLIENT_CONFIG)
        self.elb = s.client("elbv2", config=CLIENT_CONFIG)
        self.kinds = kinds
        self.interval = interval
        self.cache = {}

    def enrich(self, record):
        details = {}
        errors = []
        for kind in self.kinds:
            if record["record_type"] not in self.APPLIES_TO[kind]:
                continue
            try:
                details[kind] = getattr(self, kind)(record)
            except ClientError as e:
                details[kind] = None
                errors.append(error_entry(e))
        return {**record, "details_collected_at": now_iso(), "details": details, "errors": record["errors"] + errors}

    def pace(self, call, **params):
        """詳細を取る呼び出しは、1 回ごとに間隔を空ける。"""
        time.sleep(self.interval)
        return call(**params)

    def paged(self, client, operation, key, **params):
        """2 ページ目以降の呼び出しにも間隔を空ける。"""
        items = []
        for page in client.get_paginator(operation).paginate(**params):
            items.extend(page[key])
            time.sleep(self.interval)
        return items

    def task_definition(self, record):
        """タスク定義: 同じものは 1 回だけ引く。"""
        arn = record["task_definition"]
        key = ("task_definition", arn)
        if key not in self.cache:
            self.cache[key] = self.pace(self.ecs.describe_task_definition, taskDefinition=arn)["taskDefinition"]
        td = self.cache[key]
        platform = td.get("runtimePlatform") or {}
        return {
            "family": td.get("family"),
            "revision": td.get("revision"),
            "cpu": td.get("cpu"),
            "memory": td.get("memory"),
            "os_family": platform.get("operatingSystemFamily"),
            "cpu_architecture": platform.get("cpuArchitecture"),
            "containers": [{"name": c.get("name"), "image": c.get("image")} for c in td.get("containerDefinitions") or []],
        }

    def tasks(self, record):
        """サービスのタスクと、それが動いているホスト。"""
        cluster = record["cluster_name"]
        arns = self.paged(self.ecs, "list_tasks", "taskArns", cluster=cluster, serviceName=record["service_name"])
        tasks = [
            t for chunk in chunked(arns, 100)
            for t in self.pace(self.ecs.describe_tasks, cluster=cluster, tasks=chunk)["tasks"]
        ]
        return [
            {
                "task_arn": t.get("taskArn"),
                "task_definition": t.get("taskDefinitionArn"),
                "last_status": t.get("lastStatus"),
                "launch_type": t.get("launchType"),
                "container_instance_arn": t.get("containerInstanceArn"),
                "availability_zone": t.get("availabilityZone"),
                "started_at": utc_iso(t.get("startedAt")),
            }
            for t in tasks
        ]

    def target_health(self, record):
        """ECS サービスは自分のターゲットグループだけを見る。

        EC2 インスタンスはどこに登録されているかわからないので、すべてのターゲットグループを見る（実行ごとに 1 回）。
        """
        if record["record_type"] == "ecs_service":
            tgs = list(dict.fromkeys(lb["target_group_arn"] for lb in record["load_balancers"] if lb["target_group_arn"]))
            return [h for tg in tgs for h in self.target_health_of(tg)]
        return [h for tg in self.all_target_groups() for h in self.target_health_of(tg) if h["target_id"] == record["instance_id"]]

    def all_target_groups(self):
        if "target_groups" not in self.cache:
            groups = self.paged(self.elb, "describe_target_groups", "TargetGroups")
            self.cache["target_groups"] = [g["TargetGroupArn"] for g in groups]
        return self.cache["target_groups"]

    def target_health_of(self, tg):
        """ターゲットグループごとの結果は 1 回だけ引く。"""
        key = ("target_health", tg)
        if key not in self.cache:
            descriptions = self.pace(self.elb.describe_target_health, TargetGroupArn=tg)["TargetHealthDescriptions"]
            self.cache[key] = [
                {
                    "target_group_arn": tg,
                    "target_id": d["Target"]["Id"],
                    "port": d["Target"].get("Port"),
                    "state": (d.get("TargetHealth") or {}).get("State"),
                    "reason": (d.get("TargetHealth") or {}).get("Reason"),
                }
                for d in descriptions
            ]
        return self.cache[key]


# ------------------------------------------------------------ CLI


def parse_ec2_filter(text):
    """AWS CLI と同じ書き方（Name=tag:env,Values=prod,stg）を受け付ける。"""
    m = re.fullmatch(r"Name=([^,]+),Values=(.+)", text)
    if not m:
        raise argparse.ArgumentTypeError(f"--ec2-filter の形が違います: {text}")
    return {"Name": m[1], "Values": m[2].split(",")}


def parse_kinds(text):
    kinds = text.split(",")
    for k in kinds:
        if k not in DETAIL_KINDS:
            raise argparse.ArgumentTypeError(f"不明な詳細の種類: {k}")
    return kinds


def main(argv):
    parser = argparse.ArgumentParser(prog="compute_inventory.py")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("snapshot", help="まとめて取得できる API だけで一覧を取る")
    p.add_argument("--ec2-filter", type=parse_ec2_filter, action="append", default=[])
    p.add_argument("--cluster", action="append", default=[])

    p = sub.add_parser("detail", help="標準入力のレコードに詳細を足す")
    p.add_argument("--with", dest="kinds", type=parse_kinds, required=True, help=",".join(DETAIL_KINDS))
    p.add_argument("--interval", type=float, default=0.2)
    p.add_argument("--max", type=int, default=100)

    args = parser.parse_args(argv)
    if args.command == "snapshot":
        Snapshot(args.ec2_filter, args.cluster).run(sys.stdout)
        return

    # 件数が多すぎるときは、絞り込み忘れとみなして止める
    records = [json.loads(line) for line in sys.stdin if line.strip()]
    if len(records) > args.max:
        sys.exit(f"入力が {len(records)} 件あり、上限（--max {args.max}）を超えています。jq で絞り込むか、--max を上げてください")
    detail = Detail(args.kinds, args.interval)
    for record in records:
        write(sys.stdout, detail.enrich(record))


if __name__ == "__main__":
    main(sys.argv[1:])
