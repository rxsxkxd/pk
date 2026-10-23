#!/usr/bin/env bash
# EC2 と ECS をまとめて棚卸しする
#
#   snapshot: まとめて取得できる API だけで一覧を取り、1 件 1 行の JSONL で出す
#   detail:   標準入力のレコード（snapshot の出力を jq で絞ったもの）に、リソースごとの詳細を足す
#
# 使い方と出力の項目は ../README.md を参照。
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
patterns_file="$script_dir/../ami-os-patterns.json"
detail_kinds="task_definition tasks target_health"

# 混み合っているときは CLI が自分で間隔を空ける
export AWS_RETRY_MODE=${AWS_RETRY_MODE:-adaptive}

usage() {
  cat >&2 <<'USAGE'
usage:
  compute-inventory.sh snapshot [--ec2-filter Name=...,Values=...]... [--cluster NAME]...
  compute-inventory.sh detail --with KIND[,KIND...] [--interval SEC] [--max N] < records.jsonl

  KIND: task_definition, tasks, target_health
USAGE
  exit 1
}

die() { echo "$*" >&2; exit 1; }

for cmd in aws jq; do
  command -v "$cmd" >/dev/null || die "$cmd が必要です"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/cache"

# jq の共通の定義
# shellcheck disable=SC2016
jq_lib='
  # CLI の日時（ISO 8601 のタイムゾーン付き、または設定によってはエポック秒）を UTC の秒単位にそろえる
  def utc_iso:
    if . == null then null
    elif type == "number" then floor | todate
    else
      (capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$") // null) as $m
      | if $m == null then .
        else
          ($m.tz | if . == "Z" then 0
                   else (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)
                   end) as $offset
          | ($m.dt + "Z" | fromdateiso8601) - $offset | todate
        end
    end;
  def cluster_name: split("/")[-1];
'

# CLI のエラー文から 操作名・コード・本文 を取り出す（$1: 取り出せないときの操作名, $2: stderr のファイル）
cli_error() {
  jq -nc --arg op "$1" --arg err "$(<"$2")" '
    ($err | capture("\\((?<code>[^)]+)\\) when calling the (?<operation>[A-Za-z]+) operation: (?<message>.*)"))
      // {operation: $op, code: "Unknown", message: $err}
    | {operation, code, message}'
}

# 配列を n 件ずつ空白区切りの 1 行にする
chunks() {
  jq -r --argjson n "$1" '. as $a | range(0; length; $n) | $a[.:. + $n] | join(" ")'
}

# ---------------------------------------------------------------- snapshot

snapshot() {
  local ec2_filters=() clusters=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ec2-filter) ec2_filters+=("$2"); shift 2 ;;
      --cluster) clusters+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done

  local collected_at region
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  region=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || true)}}

  # --- EC2: 終了済みは除く。--ec2-filter はそのまま CLI に渡す
  aws ec2 describe-instances \
    --filters Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    ${ec2_filters[@]+"${ec2_filters[@]}"} \
    --output json >"$work/instances.json"

  # AMI は ID 指定だと 1 つでも登録解除済みのものがあると全体がエラーになるので、フィルタで引く
  jq '[.Reservations[].Instances[].ImageId] | unique' "$work/instances.json" | chunks 100 | tr ' ' ',' |
    while read -r ids; do
      aws ec2 describe-images --include-deprecated --filters "Name=image-id,Values=$ids" --output json </dev/null
    done >"$work/images.json"

  # SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
  local ssm_error=null
  if ! aws ssm describe-instance-information --output json >"$work/ssm.json" 2>"$work/err"; then
    echo '{"InstanceInformationList": []}' >"$work/ssm.json"
    ssm_error=$(cli_error DescribeInstanceInformation "$work/err")
  fi

  # --- ECS: --cluster が無ければすべてのクラスター
  if [ ${#clusters[@]} -eq 0 ]; then
    aws ecs list-clusters --output json | jq -r '.clusterArns[]' >"$work/clusters.txt"
  else
    printf '%s\n' "${clusters[@]}" >"$work/clusters.txt"
  fi

  : >"$work/services.jsonl"
  : >"$work/container-instances.jsonl"
  local cluster arns
  while read -r cluster; do
    aws ecs list-services --cluster "$cluster" --output json </dev/null | jq '.serviceArns' | chunks 10 |
      while read -r arns; do
        # shellcheck disable=SC2086 # ARN を別々の引数として渡す
        aws ecs describe-services --cluster "$cluster" --services $arns --output json </dev/null | jq -c '.services[]'
      done >>"$work/services.jsonl"

    # コンテナインスタンスの応答にはクラスターが入っていないので足しておく
    aws ecs list-container-instances --cluster "$cluster" --output json </dev/null | jq '.containerInstanceArns' | chunks 100 |
      while read -r arns; do
        # shellcheck disable=SC2086
        aws ecs describe-container-instances --cluster "$cluster" --container-instances $arns --output json </dev/null |
          jq -c --arg cluster "$cluster" '.containerInstances[] | . + {clusterArn: $cluster}'
      done >>"$work/container-instances.jsonl"
  done <"$work/clusters.txt"

  # --- レコードを組み立てる。ECS のホストは ec2_instance の ecs に入れる
  jq -c -n \
    --arg region "$region" \
    --arg collected_at "$collected_at" \
    --argjson ssm_error "$ssm_error" \
    --slurpfile instances "$work/instances.json" \
    --slurpfile images "$work/images.json" \
    --slurpfile ssm "$work/ssm.json" \
    --slurpfile patterns "$patterns_file" \
    --slurpfile services "$work/services.jsonl" \
    --slurpfile container_instances "$work/container-instances.jsonl" "$jq_lib"'
    def tag($k): first(.Tags[]? | select(.Key == $k) | .Value) // null;

    def os_from_ami_name($name):
      if $name == null then null
      else first($patterns[0][] | select(.pattern as $p | $name | test($p)) | .os) // null
      end;

    ([$images[].Images[]] | map({key: .ImageId, value: .}) | from_entries) as $image_by_id
    | ($ssm[0].InstanceInformationList | map({key: .InstanceId, value: .}) | from_entries) as $ssm_by_id
    | ($container_instances | map({key: .ec2InstanceId, value: .}) | from_entries) as $ci_by_id
    | (
        $instances[0].Reservations[]
        | .OwnerId as $account
        | .Instances[]
        | $image_by_id[.ImageId] as $i
        | $ssm_by_id[.InstanceId] as $s
        | $ci_by_id[.InstanceId] as $ci
        | ([$s.PlatformName, $s.PlatformVersion] | map(select(. != null and . != "")) | join(" ")) as $ssm_os
        | os_from_ami_name($i.Name) as $ami_os
        | (if $ssm_os != "" then [$ssm_os, "ssm"]
           elif $ami_os != null then [$ami_os, "ami_name"]
           else [.PlatformDetails, "platform_details"]
           end) as [$os, $os_source]
        | {
            record_type: "ec2_instance",
            account_id: $account,
            region: $region,
            collected_at: $collected_at,
            instance_id: .InstanceId,
            name: tag("Name"),
            state: .State.Name,
            instance_type: .InstanceType,
            architecture: .Architecture,
            base_os: $os,
            base_os_source: $os_source,
            image_id: .ImageId,
            launch_time: (.LaunchTime | utc_iso),
            tags: (.Tags // [] | from_entries),
            ecs: (
              if $ci == null then null
              else {
                cluster_name: ($ci.clusterArn | cluster_name),
                container_instance_arn: $ci.containerInstanceArn,
                status: $ci.status,
                agent_connected: $ci.agentConnected,
                agent_version: $ci.versionInfo.agentVersion
              }
              end
            ),
            errors: [$ssm_error | select(. != null)]
          }
      ),
      (
        $services[]
        | {
            record_type: "ecs_service",
            account_id: (.serviceArn | split(":")[4]),
            region: $region,
            collected_at: $collected_at,
            cluster_name: (.clusterArn | cluster_name),
            service_name: .serviceName,
            service_arn: .serviceArn,
            status: .status,
            launch_type: .launchType,
            desired_count: .desiredCount,
            running_count: .runningCount,
            task_definition: .taskDefinition,
            load_balancers: [
              .loadBalancers[]?
              | {target_group_arn: .targetGroupArn, container_name: .containerName, container_port: .containerPort}
            ],
            errors: []
          }
      )'
}

# ---------------------------------------------------------------- detail

# 詳細を取る呼び出しは、1 回ごとに間隔を空ける
call_aws() {
  sleep "$interval"
  aws "$@" --output json </dev/null
}

cache_file() { echo "$work/cache/${1//[^A-Za-z0-9]/_}.json"; }

# その種類の詳細が、そのレコードに当てはまるか
applies() {
  local kind=$1 type=$2
  case "$kind" in
    task_definition | tasks) [ "$type" = ecs_service ] ;;
    target_health) [ "$type" = ecs_service ] || [ "$type" = ec2_instance ] ;;
  esac
}

# タスク定義: 同じものは 1 回だけ引く
detail_task_definition() {
  local arn cache
  arn=$(jq -r '.task_definition' <<<"$1")
  cache=$(cache_file "td_$arn")
  if [ ! -s "$cache" ]; then
    call_aws ecs describe-task-definition --task-definition "$arn" >"$cache.tmp" || return 1
    mv "$cache.tmp" "$cache"
  fi
  jq -c '.taskDefinition | {
    family,
    revision,
    cpu,
    memory,
    os_family: .runtimePlatform.operatingSystemFamily,
    cpu_architecture: .runtimePlatform.cpuArchitecture,
    containers: [.containerDefinitions[] | {name, image}]
  }' "$cache"
}

# サービスのタスクと、それが動いているホスト
detail_tasks() {
  local cluster service arns
  cluster=$(jq -r '.cluster_name' <<<"$1")
  service=$(jq -r '.service_name' <<<"$1")
  call_aws ecs list-tasks --cluster "$cluster" --service-name "$service" >"$work/task-arns.json" || return 1
  jq '.taskArns' "$work/task-arns.json" | chunks 100 |
    while read -r arns; do
      # shellcheck disable=SC2086
      call_aws ecs describe-tasks --cluster "$cluster" --tasks $arns | jq -c '.tasks[]' || exit 1
    done >"$work/tasks.jsonl" || return 1
  jq -s -c "$jq_lib"'map({
    task_arn: .taskArn,
    task_definition: .taskDefinitionArn,
    last_status: .lastStatus,
    launch_type: .launchType,
    container_instance_arn: .containerInstanceArn,
    availability_zone: .availabilityZone,
    started_at: (.startedAt | utc_iso)
  })' "$work/tasks.jsonl"
}

# ターゲットグループでのヘルス。ターゲットグループごとの結果は 1 回だけ引く
target_health_of() {
  local tg=$1 cache
  cache=$(cache_file "tg_$tg")
  if [ ! -s "$cache" ]; then
    call_aws elbv2 describe-target-health --target-group-arn "$tg" >"$cache.tmp" || return 1
    mv "$cache.tmp" "$cache"
  fi
  jq -c --arg tg "$tg" '.TargetHealthDescriptions[] | {
    target_group_arn: $tg,
    target_id: .Target.Id,
    port: .Target.Port,
    state: .TargetHealth.State,
    reason: .TargetHealth.Reason
  }' "$cache"
}

# ECS サービスは自分のターゲットグループだけを見る。
# EC2 インスタンスはどこに登録されているかわからないので、すべてのターゲットグループを見る（実行ごとに 1 回）
detail_target_health() {
  local type tgs tg instance_id
  type=$(jq -r '.record_type' <<<"$1")
  if [ "$type" = ecs_service ]; then
    tgs=$(jq -r '[.load_balancers[].target_group_arn | select(. != null)] | unique[]' <<<"$1")
  else
    if [ ! -s "$work/cache/target-groups.txt" ]; then
      call_aws elbv2 describe-target-groups | jq -r '.TargetGroups[].TargetGroupArn' >"$work/cache/target-groups.txt" || return 1
    fi
    tgs=$(<"$work/cache/target-groups.txt")
  fi
  instance_id=$(jq -r '.instance_id // ""' <<<"$1")

  for tg in $tgs; do
    target_health_of "$tg" || return 1
  done >"$work/health.jsonl"
  jq -s -c --arg type "$type" --arg id "$instance_id" \
    'if $type == "ec2_instance" then map(select(.target_id == $id)) else . end' "$work/health.jsonl"
}

detail() {
  local kinds="" max=100 kind
  interval=0.2
  while [ $# -gt 0 ]; do
    case "$1" in
      --with) kinds=${2//,/ }; shift 2 ;;
      --interval) interval=$2; shift 2 ;;
      --max) max=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$kinds" ] || usage
  for kind in $kinds; do
    case " $detail_kinds " in *" $kind "*) ;; *) die "不明な詳細の種類: $kind" ;; esac
  done

  # 件数が多すぎるときは、絞り込み忘れとみなして止める
  cat >"$work/input.jsonl"
  local count
  count=$(grep -c . "$work/input.jsonl" || true)
  [ "$count" -le "$max" ] || die "入力が $count 件あり、上限（--max $max）を超えています。jq で絞り込むか、--max を上げてください"

  local record type details errors result
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    type=$(jq -r '.record_type' <<<"$record")
    details='{}'
    errors='[]'
    for kind in $kinds; do
      applies "$kind" "$type" || continue
      if result=$("detail_$kind" "$record" 2>"$work/err"); then
        details=$(jq -c --arg k "$kind" --argjson v "$result" '.[$k] = $v' <<<"$details")
      else
        details=$(jq -c --arg k "$kind" '.[$k] = null' <<<"$details")
        errors=$(jq -c --argjson e "$(cli_error "$kind" "$work/err")" '. + [$e]' <<<"$errors")
      fi
    done
    jq -c --argjson d "$details" --argjson e "$errors" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + {details_collected_at: $at, details: $d, errors: (.errors + $e)}' <<<"$record"
  done <"$work/input.jsonl"
}

# ----------------------------------------------------------------

case "${1:-}" in
  snapshot) shift; snapshot "$@" ;;
  detail) shift; detail "$@" ;;
  *) usage ;;
esac
