"""ECS のサービスとコンテナインスタンスの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import chunked, tags_object, utc_iso

TOOL = "ecs_inventory.py"
SNAPSHOT_OPTIONS = [("--cluster", "対象のクラスター（名前か ARN）。指定しなければすべてのクラスター")]


def cluster_name(arn):
    return arn.split("/")[-1]


def snapshot(ctx, opts):
    clusters = opts["cluster"] or ctx.call("ecs", "list_clusters", {})["clusterArns"]
    services = []
    instances = []
    for cluster in clusters:
        arns = ctx.call("ecs", "list_services", {"cluster": cluster})["serviceArns"]
        for chunk in chunked(arns, 10):
            params = {"cluster": cluster, "services": chunk, "include": ["TAGS"]}
            services += ctx.call("ecs", "describe_services", params)["services"]
        # コンテナインスタンスの応答にはクラスターが入っていないので、クラスターと組にしておく
        arns = ctx.call("ecs", "list_container_instances", {"cluster": cluster})["containerInstanceArns"]
        for chunk in chunked(arns, 100):
            params = {"cluster": cluster, "containerInstances": chunk}
            instances += [(cluster, ci) for ci in ctx.call("ecs", "describe_container_instances", params)["containerInstances"]]

    for s in services:
        yield service_record(ctx, s)
    for cluster, ci in instances:
        yield container_instance_record(ctx, cluster, ci)


def service_record(ctx, s):
    awsvpc = (s.get("networkConfiguration") or {}).get("awsvpcConfiguration")
    breaker = (s.get("deploymentConfiguration") or {}).get("deploymentCircuitBreaker")
    return ctx.record("ecs_service", {
        "cluster_name": cluster_name(s["clusterArn"]),
        "service_name": s.get("serviceName"),
        "service_arn": s.get("serviceArn"),
        "status": s.get("status"),
        "launch_type": s.get("launchType"),
        "capacity_provider_strategy": [
            {"capacity_provider": p.get("capacityProvider"), "weight": p.get("weight"), "base": p.get("base")}
            for p in s.get("capacityProviderStrategy") or []
        ],
        "platform_version": s.get("platformVersion"),
        "platform_family": s.get("platformFamily"),
        "scheduling_strategy": s.get("schedulingStrategy"),
        "desired_count": s.get("desiredCount"),
        "running_count": s.get("runningCount"),
        "pending_count": s.get("pendingCount"),
        "task_definition": s.get("taskDefinition"),
        "load_balancers": [
            {
                "target_group_arn": lb.get("targetGroupArn"),
                "load_balancer_name": lb.get("loadBalancerName"),
                "container_name": lb.get("containerName"),
                "container_port": lb.get("containerPort"),
            }
            for lb in s.get("loadBalancers") or []
        ],
        "service_registries": [r.get("registryArn") for r in s.get("serviceRegistries") or []],
        "network": {
            "subnets": awsvpc.get("subnets") or [],
            "security_groups": awsvpc.get("securityGroups") or [],
            "assign_public_ip": awsvpc.get("assignPublicIp"),
        } if awsvpc else None,
        "deployment_circuit_breaker": {"enable": breaker.get("enable"), "rollback": breaker.get("rollback")} if breaker else None,
        "enable_execute_command": s.get("enableExecuteCommand"),
        "created_at": utc_iso(s.get("createdAt")),
        "tags": tags_object(s.get("tags")),
    })


def container_instance_record(ctx, cluster, ci):
    attributes = {a["name"]: a.get("value") for a in ci.get("attributes") or []}
    version = ci.get("versionInfo") or {}
    return ctx.record("ecs_container_instance", {
        "cluster_name": cluster_name(cluster),
        "container_instance_arn": ci.get("containerInstanceArn"),
        "ec2_instance_id": ci.get("ec2InstanceId"),
        "status": ci.get("status"),
        "agent_connected": ci.get("agentConnected"),
        "agent_version": version.get("agentVersion"),
        "docker_version": version.get("dockerVersion"),
        "os_type": attributes.get("ecs.os-type"),
        "os_family": attributes.get("ecs.os-family"),
        "cpu_architecture": attributes.get("ecs.cpu-architecture"),
        "ami_id": attributes.get("ecs.ami-id"),
        "instance_type": attributes.get("ecs.instance-type"),
        "capacity_provider_name": ci.get("capacityProviderName"),
        "running_tasks_count": ci.get("runningTasksCount"),
        "pending_tasks_count": ci.get("pendingTasksCount"),
        "registered_at": utc_iso(ci.get("registeredAt")),
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


def tasks(ctx, record):
    """サービスのタスクと、それが動いているホスト。"""
    cluster = record["cluster_name"]
    arns = ctx.call("ecs", "list_tasks", {"cluster": cluster, "serviceName": record["service_name"]})["taskArns"]
    result = []
    for chunk in chunked(arns, 100):
        for t in ctx.call("ecs", "describe_tasks", {"cluster": cluster, "tasks": chunk})["tasks"]:
            result.append({
                "task_arn": t.get("taskArn"),
                "task_definition": t.get("taskDefinitionArn"),
                "last_status": t.get("lastStatus"),
                "desired_status": t.get("desiredStatus"),
                "health_status": t.get("healthStatus"),
                "launch_type": t.get("launchType"),
                "container_instance_arn": t.get("containerInstanceArn"),
                "availability_zone": t.get("availabilityZone"),
                "started_at": utc_iso(t.get("startedAt")),
            })
    return result


DETAIL_KINDS = {
    "task_definition": (("ecs_service",), task_definition),
    "tasks": (("ecs_service",), tasks),
}
