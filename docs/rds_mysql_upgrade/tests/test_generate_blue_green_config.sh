#!/usr/bin/env bash
# Blue/Green 設定生成支援ツールのテスト。
# 実 AWS には接続せず、examples/ の describe-db-instances ダミー応答を使う。
# 出力はすべて一時ディレクトリに限定し、config/blue-green/{staging,production}.deployment.yml を変更しない。
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
fixture_dir="$repo_root/examples/config-blue-green-generation"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-config-generator-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/bin" "$work_dir/output"

# AWS CLI のダミー。収集器が組み立てる引数を 1 行ずつ記録し、
# describe-db-instances と describe-db-parameters を fixture から返し分ける。
# 読み取り API 以外を呼んだ場合は失敗させる。
cat > "$work_dir/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$AWS_MOCK_ARGUMENTS"
group=''
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == --db-parameter-group-name ]]; then
    next=$((i + 1)); group=${!next}
  fi
done
case " $* " in
  *' describe-db-instances '*)
    cat "$AWS_MOCK_INSTANCES" ;;
  *' describe-db-parameters '*)
    cat "$AWS_MOCK_PARAMETERS_DIR/${group}.json" ;;
  *)
    echo "unexpected AWS CLI call: $*" >&2; exit 64 ;;
esac
MOCK
chmod +x "$work_dir/bin/aws"

AWS_MOCK_ARGUMENTS="$work_dir/aws-arguments.txt" \
AWS_MOCK_INSTANCES="$fixture_dir/rds-instance-inventory.test.json" \
AWS_MOCK_PARAMETERS_DIR="$fixture_dir/describe-db-parameters" \
PATH="$work_dir/bin:$PATH" \
go -C "$repo_root" run ./scripts/collect_rds_instance_inventory \
  --region ap-northeast-1 \
  --profile test-readonly \
  --output "$work_dir/rds-instance-inventory.json"

# 読み取り API だけを、パラメータグループごとに 1 回ずつ呼んでいること。
python3 - "$work_dir/aws-arguments.txt" "$fixture_dir/rds-instance-inventory.test.json" <<'PY'
import json
import sys

calls = [line.strip() for line in open(sys.argv[0 + 1], encoding="utf-8") if line.strip()]
response = json.load(open(sys.argv[2], encoding="utf-8"))
prefix = "--region ap-northeast-1 --profile test-readonly rds "

assert calls[0] == prefix + "describe-db-instances --output json", calls[0]

groups = sorted({
    group["DBParameterGroupName"]
    for instance in response["DBInstances"]
    for group in instance["DBParameterGroups"]
})
expected = sorted(
    prefix + f"describe-db-parameters --db-parameter-group-name {name} --output json"
    for name in groups
)
assert sorted(calls[1:]) == expected, calls[1:]
assert len(calls[1:]) == len(groups), "each parameter group must be read exactly once"
PY
python3 - "$fixture_dir/rds-instance-inventory.test.json" "$work_dir/rds-instance-inventory.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    expected_response = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    inventory = json.load(handle)
assert inventory["aws_region"] == "ap-northeast-1"
assert inventory["DBInstances"] == expected_response["DBInstances"]
# パラメータグループごとに、採取対象パラメータの実値が入っていること。
groups = {
    group["DBParameterGroupName"]
    for instance in expected_response["DBInstances"]
    for group in instance["DBParameterGroups"]
}
assert set(inventory["ParameterGroups"]) == groups, inventory["ParameterGroups"]
for name, facts in inventory["ParameterGroups"].items():
    assert set(facts) == {"Parameters"}, name
    assert "time_zone" in facts["Parameters"], name
    for parameter, value in facts["Parameters"].items():
        assert set(value) == {"Value", "Source"}, f"{name}.{parameter}"
        assert value["Value"] and value["Source"], f"{name}.{parameter}"
PY

for environment in development staging production; do
  # go.mod はリポジトリ直下にある。ここでは呼び出し元の cwd に依存しないよう
  # -C でリポジトリ直下を指定し、入出力は絶対パスで渡す。
  go -C "$repo_root" run ./scripts/generate_blue_green_config \
    --catalog "$fixture_dir/migration-catalog.test.yml" \
    --inventory "$work_dir/rds-instance-inventory.json" \
    --environment "$environment" \
    --output "$work_dir/output/$environment.yml"

  # レポートは YAML 生成とは別コマンドである。同じ入力から Markdown を組み立てる。
  go -C "$repo_root" run ./scripts/generate_blue_green_config_report \
    --catalog "$fixture_dir/migration-catalog.test.yml" \
    --inventory "$work_dir/rds-instance-inventory.json" \
    --environment "$environment" \
    --output "$work_dir/output/$environment.report.md"
  diff -u "$fixture_dir/blue-green.$environment.report.expected.md" \
    "$work_dir/output/$environment.report.md" || {
    echo "generated report differs from the expected test result: $environment" >&2
    exit 1
  }

  python3 - "$work_dir/output/$environment.yml" "$fixture_dir/blue-green.$environment.expected.yml" "$fixture_dir/migration-catalog.test.yml" "$environment" "$work_dir/rds-instance-inventory.json" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    actual = yaml.safe_load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    expected = yaml.safe_load(handle)
with open(sys.argv[3], encoding="utf-8") as handle:
    catalog = yaml.safe_load(handle)
environment = sys.argv[4]
with open(sys.argv[5], encoding="utf-8") as handle:
    import json
    inventory_facts = json.load(handle)["ParameterGroups"]

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

# 同じインスタンスを指す接続は 1 エントリへまとめ、schemas を集約する。
for instance in instances:
    service = actual["services"][instance]
    expected_schemas = sorted(
        {b["schema_name"] for _, _, b in bindings if b["rds_instance"] == instance}
    )
    assert service["schemas"] == expected_schemas, instance
    # target を省略した接続は、共通ターゲットと Blue の実値で補完される。
    assert service["target_engine_version"]
    assert service["target_db_instance_class"]
    # 確認用のパラメータ実値は、Blue のパラメータグループの収集値をそのまま載せる。
    facts = inventory_facts[service["source_db_parameter_group_name"]]["Parameters"]
    assert service["source_db_parameters"] == {
        name: {"value": value["Value"], "source": value["Source"]}
        for name, value in facts.items()
    }, instance

# mysql_verification は、ルートの既定値を接続配下がキー単位で上書きする。
# auth_method は parameter_store 固定で、user はカタログに置かない。
defaults = catalog.get("mysql_verification") or {}
for instance in instances:
    verification = actual["services"][instance]["mysql_verification"]
    assert verification["auth_method"] == "parameter_store", instance
    # user はカタログに書けないため、生成結果にもキー自体が現れない。
    assert "user" not in verification, instance
    overrides = [
        b.get("mysql_verification") or {}
        for _, _, b in bindings if b["rds_instance"] == instance
    ]
    merged = dict(defaults)
    for override in overrides:
        merged.update(override)
    for key in ("enabled", "parameter_name", "user_parameter_name", "port"):
        if key in merged:
            assert verification[key] == merged[key], f"{instance}.{key}"
    if merged.get("enabled"):
        assert verification["parameter_name"], instance
        assert verification["user_parameter_name"], instance

print(f"Blue/Green config generator {environment}: OK "
      f"({len(bindings)} connections -> {len(instances)} deployments)")
PY
done
