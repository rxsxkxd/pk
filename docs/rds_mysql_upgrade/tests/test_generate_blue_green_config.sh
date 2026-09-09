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
cmp -- "$fixture_dir/rds-instance-inventory.test.json" "$work_dir/rds-instance-inventory.json"

python3 "$repo_root/scripts/generate_blue_green_config.py" \
  --catalog "$fixture_dir/migration-catalog.test.yml" \
  --inventory "$work_dir/rds-instance-inventory.json" \
  --environment test \
  --output "$work_dir/output/test.yml"

python3 - "$work_dir/output/test.yml" "$fixture_dir/blue-green.test.expected.yml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    actual = yaml.safe_load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    expected = yaml.safe_load(handle)

assert actual == expected, "generated YAML differs from the expected test result"
print("Blue/Green config generator test: OK")
PY
