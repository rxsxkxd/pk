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
databases = catalog["databases"]
assert len(databases) == 2, "test fixture must contain multiple database roots"
primaries = [database["environments"][environment]["primary"] for database in databases.values()]
assert len({primary["host"]["rds_instance_identifier"] for primary in primaries}) == 2
print(f"Blue/Green config generator {environment}: OK")
PY
done
