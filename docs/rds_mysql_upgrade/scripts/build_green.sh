#!/usr/bin/env bash
# Step 3: 承認済みの保護スナップショット取得と Blue/Green Green 環境の作成を行う。
set -euo pipefail

usage() { echo 'Usage: build_green.sh --config FILE --service NAME [--region REGION] [--profile PROFILE] [--output-dir DIR]'; }
config=''; service=''; region=''; profile=''; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" ]] || { usage >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-build.XXXXXX")
mkdir -p "$output_dir"

# 設定ファイルの承認宣言と、スナップショット・移行元 DB の識別子を取得する。AWS API は呼び出さない。
python3 -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])); s=d["services"][sys.argv[2]]; a=s.get("actions", {}); [(_ for _ in ()).throw(SystemExit(f"missing {k}")) for k in ("source_db_instance_identifier", "protection_snapshot_identifier") if not s.get(k)]; print(json.dumps({"build":a.get("build", "pending"), "source":s["source_db_instance_identifier"], "snapshot":s["protection_snapshot_identifier"], "region":d["aws_region"]}))' "$config" "$service" > "$output_dir/config.json"
read_config() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$output_dir/config.json" "$1"; }
[[ "$(read_config build)" == approved ]] || { echo 'build: pending; no changes made.'; exit 0; }
source_id=$(read_config source); snapshot_id=$(read_config snapshot)
[[ -n "$region" ]] || region=$(read_config region)
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り] 移行元 ARN を取得し、同じ Source の Blue/Green Deployment が既にあれば二重作成しない。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" --output json > "$output_dir/source.json"
source_arn=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["DBInstances"][0]["DBInstanceArn"])' "$output_dir/source.json")
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployments.json"
existing_id=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["BlueGreenDeployments"]; print(d[0].get("BlueGreenDeploymentIdentifier", "") if d else "")' "$output_dir/deployments.json")
if [[ -n "$existing_id" ]]; then
  echo "Blue/Green Deployment already exists: $existing_id"
  echo "Artifacts: $output_dir"
  exit 0
fi

# [変更] 同名の保護スナップショットがなければ作成する。切り戻し可能な状態を確保するための操作。
if aws "${aws_args[@]}" rds describe-db-snapshots --db-snapshot-identifier "$snapshot_id" --output json > "$output_dir/snapshot.json" 2>/dev/null; then
  echo "Protection snapshot already exists: $snapshot_id"
else
  aws "${aws_args[@]}" rds create-db-snapshot --db-instance-identifier "$source_id" --db-snapshot-identifier "$snapshot_id" --output json > "$output_dir/create-snapshot.json"
fi

# [読み取り待機] 保護スナップショットが available になるまで待ち、作成前の復旧可能性を確定する。
aws "${aws_args[@]}" rds wait db-snapshot-available --db-snapshot-identifier "$snapshot_id"

create_args=(--config "$config" --service "$service" --region "$region" --output-dir "$output_dir/blue-green")
[[ -n "$profile" ]] && create_args+=(--profile "$profile")
"$(dirname "$0")/create_blue_green_deployment.sh" "${create_args[@]}"
echo "Build completed. Artifacts: $output_dir"
