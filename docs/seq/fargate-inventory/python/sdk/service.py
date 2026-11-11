"""Fargate で動いているタスクの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import chunked, tags_object, utc_iso

TOOL = "fargate_inventory.py"
SNAPSHOT_OPTIONS = [("--cluster", "対象のクラスター（名前か ARN）。指定しなければすべてのクラスター")]


def snapshot(ctx, opts):
    clusters = opts["cluster"] or ctx.call("ecs", "list_clusters", {})["clusterArns"]
    # 動いている（RUNNING を目指している）Fargate のタスクを、クラスターごとに 100 件ずつまとめて引く
    for cluster in clusters:
        arns = ctx.call("ecs", "list_tasks", {"cluster": cluster, "launchType": "FARGATE"})["taskArns"]
        for chunk in chunked(arns, 100):
            for t in ctx.call("ecs", "describe_tasks", {"cluster": cluster, "tasks": chunk, "include": ["TAGS"]})["tasks"]:
                yield task_record(ctx, t)


def eni_detail(task, name):
    for a in task.get("attachments") or []:
        if a.get("type") == "ElasticNetworkInterface":
            for d in a.get("details") or []:
                if d.get("name") == name:
                    return d.get("value")
    return None


def task_record(ctx, t):
    group = t.get("group") or ""
    return ctx.record("fargate_task", {
        "cluster_name": t["clusterArn"].split("/")[-1],
        "task_arn": t.get("taskArn"),
        "task_definition": t.get("taskDefinitionArn"),
        "group": t.get("group"),
        "service_name": group[len("service:"):] if group.startswith("service:") else None,
        "started_by": t.get("startedBy"),
        "last_status": t.get("lastStatus"),
        "desired_status": t.get("desiredStatus"),
        "health_status": t.get("healthStatus"),
        "capacity_provider_name": t.get("capacityProviderName"),
        "platform_version": t.get("platformVersion"),
        "platform_family": t.get("platformFamily"),
        "cpu": t.get("cpu"),
        "memory": t.get("memory"),
        "ephemeral_storage_gib": (t.get("ephemeralStorage") or {}).get("sizeInGiB"),
        "availability_zone": t.get("availabilityZone"),
        "subnet_id": eni_detail(t, "subnetId"),
        "private_ipv4_address": eni_detail(t, "privateIPv4Address"),
        "network_interface_id": eni_detail(t, "networkInterfaceId"),
        "enable_execute_command": t.get("enableExecuteCommand"),
        "started_at": utc_iso(t.get("startedAt")),
        "tags": tags_object(t.get("tags")),
    })


def task_definition(ctx, record):
    """タスク定義の要約。同じタスク定義は 1 回だけ引く。"""
    arn = record["task_definition"]
    td = ctx.cached(("td", arn), lambda: ctx.call("ecs", "describe_task_definition", {"taskDefinition": arn})["taskDefinition"])
    platform = td.get("runtimePlatform") or {}
    return {
        "family": td.get("family"),
        "revision": td.get("revision"),
        "status": td.get("status"),
        "cpu": td.get("cpu"),
        "memory": td.get("memory"),
        "os_family": platform.get("operatingSystemFamily"),
        "cpu_architecture": platform.get("cpuArchitecture"),
        "network_mode": td.get("networkMode"),
        "requires_compatibilities": td.get("requiresCompatibilities") or [],
        "task_role_arn": td.get("taskRoleArn"),
        "execution_role_arn": td.get("executionRoleArn"),
        "containers": [
            {
                "name": c.get("name"),
                "image": c.get("image"),
                "essential": c.get("essential"),
                "cpu": c.get("cpu"),
                "memory": c.get("memory"),
                "memory_reservation": c.get("memoryReservation"),
                "port_mappings": [
                    {"container_port": pm.get("containerPort"), "host_port": pm.get("hostPort"), "protocol": pm.get("protocol")}
                    for pm in c.get("portMappings") or []
                ],
                "log_driver": (c.get("logConfiguration") or {}).get("logDriver"),
            }
            for c in td.get("containerDefinitions") or []
        ],
    }


DETAIL_KINDS = {
    "task_definition": (("fargate_task",), task_definition),
}
