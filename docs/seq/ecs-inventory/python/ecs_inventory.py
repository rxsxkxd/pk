#!/usr/bin/env python3
"""ECS のサービスとコンテナインスタンスを 1 件 1 行の JSONL で出力する。

API 呼び出しは ListClusters と、クラスターごとの ListServices / ListContainerInstances（ページ分）、
それを 10 件（サービス）・100 件（コンテナインスタンス）ずつまとめた Describe 系、
使われているタスク定義ごとの DescribeTaskDefinition だけ。出力の項目は ../README.md を参照。
"""

import json
import os
import sys
from datetime import timezone

import boto3
from botocore.exceptions import ClientError


def run(client, out):
    clusters = paginate(client, "list_clusters", "clusterArns")
    services = [s for cluster in clusters for s in describe_services(client, cluster)]
    instances = [pair for cluster in clusters for pair in describe_container_instances(client, cluster)]
    task_definitions = {}
    for service in services:
        arn = service["taskDefinition"]
        if arn not in task_definitions:
            task_definitions[arn] = fetch_task_definition(client, arn)

    for service in services:
        write(out, service_record(service, *task_definitions[service["taskDefinition"]]))
    for cluster, instance in instances:
        write(out, container_instance_record(cluster, instance))


def write(out, rec):
    out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def paginate(client, operation, key, **params):
    return [item for page in client.get_paginator(operation).paginate(**params) for item in page[key]]


def chunked(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def describe_services(client, cluster):
    arns = paginate(client, "list_services", "serviceArns", cluster=cluster)
    return [
        s for chunk in chunked(arns, 10)
        for s in client.describe_services(cluster=cluster, services=chunk)["services"]
    ]


def describe_container_instances(client, cluster):
    """コンテナインスタンスの応答にはクラスターが入っていないので、組にして返す。"""
    arns = paginate(client, "list_container_instances", "containerInstanceArns", cluster=cluster)
    return [
        (cluster, i) for chunk in chunked(arns, 100)
        for i in client.describe_container_instances(cluster=cluster, containerInstances=chunk)["containerInstances"]
    ]


def fetch_task_definition(client, arn):
    """取れなかったタスク定義は、そのサービスの errors に記録して続ける。"""
    try:
        return client.describe_task_definition(taskDefinition=arn)["taskDefinition"], None
    except ClientError as e:
        err = e.response["Error"]
        return None, {"operation": "DescribeTaskDefinition", "code": err["Code"], "message": err.get("Message")}


def service_record(service, td, error):
    td = td or {}
    runtime_platform = td.get("runtimePlatform") or {}
    awsvpc = (service.get("networkConfiguration") or {}).get("awsvpcConfiguration")
    breaker = (service.get("deploymentConfiguration") or {}).get("deploymentCircuitBreaker")
    return {
        "record_type": "service",
        "cluster_name": cluster_name(service["clusterArn"]),
        "service_name": service.get("serviceName"),
        "service_arn": service.get("serviceArn"),
        "status": service.get("status"),
        "launch_type": service.get("launchType"),
        "capacity_provider_strategy": [
            {"capacity_provider": s.get("capacityProvider"), "weight": s.get("weight"), "base": s.get("base")}
            for s in service.get("capacityProviderStrategy") or []
        ],
        "platform_version": service.get("platformVersion"),
        "platform_family": service.get("platformFamily"),
        "scheduling_strategy": service.get("schedulingStrategy"),
        "desired_count": service.get("desiredCount"),
        "running_count": service.get("runningCount"),
        "pending_count": service.get("pendingCount"),
        "task_definition": service.get("taskDefinition"),
        "cpu": td.get("cpu"),
        "memory": td.get("memory"),
        "os_family": runtime_platform.get("operatingSystemFamily"),
        "cpu_architecture": runtime_platform.get("cpuArchitecture"),
        "network_mode": td.get("networkMode"),
        "requires_compatibilities": td.get("requiresCompatibilities") or [],
        "task_role_arn": td.get("taskRoleArn"),
        "execution_role_arn": td.get("executionRoleArn"),
        "containers": [container(c) for c in td.get("containerDefinitions") or []],
        "load_balancers": [
            {
                "target_group_arn": lb.get("targetGroupArn"),
                "load_balancer_name": lb.get("loadBalancerName"),
                "container_name": lb.get("containerName"),
                "container_port": lb.get("containerPort"),
            }
            for lb in service.get("loadBalancers") or []
        ],
        "service_registries": [r.get("registryArn") for r in service.get("serviceRegistries") or []],
        "network": {
            "subnets": awsvpc.get("subnets") or [],
            "security_groups": awsvpc.get("securityGroups") or [],
            "assign_public_ip": awsvpc.get("assignPublicIp"),
        } if awsvpc else None,
        "deployment_circuit_breaker": {
            "enable": breaker.get("enable"),
            "rollback": breaker.get("rollback"),
        } if breaker else None,
        "enable_execute_command": service.get("enableExecuteCommand"),
        "created_at": utc_iso(service.get("createdAt")),
        "errors": [error] if error else [],
    }


def container(definition):
    return {
        "name": definition.get("name"),
        "image": definition.get("image"),
        "essential": definition.get("essential"),
        "cpu": definition.get("cpu"),
        "memory": definition.get("memory"),
        "memory_reservation": definition.get("memoryReservation"),
        "port_mappings": [
            {"container_port": pm.get("containerPort"), "host_port": pm.get("hostPort"), "protocol": pm.get("protocol")}
            for pm in definition.get("portMappings") or []
        ],
        "log_driver": (definition.get("logConfiguration") or {}).get("logDriver"),
    }


def container_instance_record(cluster, instance):
    attributes = {a["name"]: a.get("value") for a in instance.get("attributes") or []}
    version = instance.get("versionInfo") or {}
    return {
        "record_type": "container_instance",
        "cluster_name": cluster_name(cluster),
        "container_instance_arn": instance.get("containerInstanceArn"),
        "ec2_instance_id": instance.get("ec2InstanceId"),
        "status": instance.get("status"),
        "agent_connected": instance.get("agentConnected"),
        "agent_version": version.get("agentVersion"),
        "docker_version": version.get("dockerVersion"),
        "os_type": attributes.get("ecs.os-type"),
        "os_family": attributes.get("ecs.os-family"),
        "cpu_architecture": attributes.get("ecs.cpu-architecture"),
        "ami_id": attributes.get("ecs.ami-id"),
        "instance_type": attributes.get("ecs.instance-type"),
        "capacity_provider_name": instance.get("capacityProviderName"),
        "running_tasks_count": instance.get("runningTasksCount"),
        "pending_tasks_count": instance.get("pendingTasksCount"),
        "registered_at": utc_iso(instance.get("registeredAt")),
        "errors": [],
    }


def cluster_name(arn):
    return arn.split("/")[-1]


def utc_iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def main():
    # AWS_REGION は boto3 の版によっては読まれないので明示的に渡す（未設定ならプロファイルの設定に従う）
    client = boto3.client("ecs", region_name=os.environ.get("AWS_REGION"))
    run(client, sys.stdout)


if __name__ == "__main__":
    main()
