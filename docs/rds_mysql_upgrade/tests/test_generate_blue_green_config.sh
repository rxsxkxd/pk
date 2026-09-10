#!/usr/bin/env bash
# Blue/Green 設定生成支援ツールのテスト。
# 実 AWS には接続せず、examples/ の describe-db-instances ダミー応答を使う。
# 出力はすべて一時ディレクトリに限定し、config/blue-green/{staging,production}.yml を変更しない。
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
fixture_dir="$repo_root/examples/config-blue-green-generation"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-config-generator-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/bin" "$work_dir/output"

# AWS CLI のダミー。収集スクリプトが組み立てる引数を記録し、固定の RDS 応答を返す。
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" > "$AWS_MOCK_ARGUMENTS"' \
  'cat "$AWS_MOCK_RESPONSE"' \
  > "$work_dir/bin/aws"
chmod +x "$work_dir/bin/aws"

AWS_MOCK_ARGUMENTS="$work_dir/aws-arguments.txt" \
AWS_MOCK_RESPONSE="$fixture_dir/rds-instance-inventory.test.json" \
PATH="$work_dir/bin:$PATH" \
"$repo_root/scripts/collect_rds_instance_inventory.sh" \
  --region ap-northeast-1 \
  --profile test-readonly \
  --output "$work_dir/rds-instance-inventory.json"

expected_arguments='--region ap-northeast-1 --profile test-readonly rds describe-db-instances --output json'
[[ "$(<"$work_dir/aws-arguments.txt")" == "$expected_arguments" ]] || {
  echo 'collector did not call the expected read-only AWS CLI command' >&2
  exit 1
}
python3 - "$fixture_dir/rds-instance-inventory.test.json" "$work_dir/rds-instance-inventory.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    expected_response = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    inventory = json.load(handle)
assert inventory["aws_region"] == "ap-northeast-1"
assert inventory["DBInstances"] == expected_response["DBInstances"]
PY

for environment in development staging production; do
  python3 "$repo_root/scripts/generate_blue_green_config.py" \
    --catalog "$fixture_dir/migration-catalog.test.yml" \
    --inventory "$work_dir/rds-instance-inventory.json" \
    --environment "$environment" \
    --output "$work_dir/output/$environment.yml"

  python3 - "$work_dir/output/$environment.yml" "$fixture_dir/blue-green.$environment.expected.yml" "$fixture_dir/migration-catalog.test.yml" "$environment" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    actual = yaml.safe_load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    expected = yaml.safe_load(handle)
with open(sys.argv[3], encoding="utf-8") as handle:
    catalog = yaml.safe_load(handle)
environment = sys.argv[4]

assert actual == expected, "generated YAML differs from the expected test result"

# カタログが新構造であること、および生成の要点を確認する。
applications = catalog["applications"]
assert len(applications) >= 2, "test fixture must contain multiple applications"
assert environment in catalog["database_environments"]

# その環境の接続を集め、生成単位（インスタンス）へ正しくまとめられたかを見る。
bindings = [
    (name, connection_name, binding)
    for name, application in applications.items()
    for connection_name, connection in application["connections"].items()
    for env, binding in (connection.get("environments") or {}).items()
    if env == environment
]
assert bindings, f"test fixture has no connection for {environment}"
instances = {binding["rds_instance"] for _, _, binding in bindings}
assert set(actual["services"]) == instances, "services keys must be the RDS instances"

# 同じインスタンスを指す接続は 1 エントリへまとめ、schemas と connected_by を集約する。
for instance in instances:
    service = actual["services"][instance]
    expected_schemas = sorted(
        {b["schema_name"] for _, _, b in bindings if b["rds_instance"] == instance}
    )
    expected_connected = sorted(
        {f"{a}.{c}" for a, c, b in bindings if b["rds_instance"] == instance}
    )
    assert service["schemas"] == expected_schemas, instance
    assert service["connected_by"] == expected_connected, instance
    # target を省略した接続は、共通ターゲットと Blue の実値で補完される。
    assert service["target_engine_version"]
    assert service["target_db_instance_class"]

print(f"Blue/Green config generator {environment}: OK "
      f"({len(bindings)} connections -> {len(instances)} deployments)")
PY
done
