#!/usr/bin/env bash
# 構築前チェック（scripts/check_target_parameter_group.rb）のテスト。AWS へは接続しない。
# 移行先パラメータグループが名前どおり 1 件あり、family が目標バージョンと合うときだけ通ること、
# 不適合でもレポートを残すことを確かめる。
set -uo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0
config=config/blue-green/staging.deployment.yml
vars=$(ruby scripts/lib/deployment_config.rb vars "$config" example-service tpg=required:service.target_db_parameter_group_name)
eval "$vars"
mkdir -p "$work/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls.log"\ncat "%s/response.json"\n' "$work" "$work" > "$work/bin/aws"
chmod +x "$work/bin/aws"

check() {  # $1=説明 $2=応答 JSON $3=期待する終了コード $4=レポートの判定
  local desc=$1 response=$2 want=$3 verdict=$4
  printf '%s\n' "$response" > "$work/response.json"; rm -rf "$work/out" "$work/calls.log"
  PATH="$work/bin:$PATH" ruby scripts/check_target_parameter_group.rb --config "$config" --service example-service \
    --output-dir "$work/out" >/dev/null 2>"$work/err"
  local status=$?
  if [[ $status -ne $want ]]; then
    printf 'FAIL  %-44s 終了コード %s（期待 %s）: %s\n' "$desc" "$status" "$want" "$(cat "$work/err")"; failed=$((failed + 1)); return
  fi
  if [[ -n "$verdict" ]] && ! grep -q "判定: $verdict" "$work/out/target-parameter-group-check.md"; then
    printf 'FAIL  %-44s レポートの判定が %s でない\n' "$desc" "$verdict"; failed=$((failed + 1)); return
  fi
  if ! grep -q -- "describe-db-parameter-groups --db-parameter-group-name $tpg " "$work/calls.log"; then
    printf 'FAIL  %-44s 読み取り以外、または別の名前を引いた: %s\n' "$desc" "$(cat "$work/calls.log")"; failed=$((failed + 1)); return
  fi
  printf 'ok    %s\n' "$desc"
}
check '名前と family が合えば通る'   "{\"DBParameterGroups\":[{\"DBParameterGroupName\":\"$tpg\",\"DBParameterGroupFamily\":\"mysql8.4\"}]}" 0 PASS
check 'family が違えば止める'        "{\"DBParameterGroups\":[{\"DBParameterGroupName\":\"$tpg\",\"DBParameterGroupFamily\":\"mysql8.0\"}]}" 1 FAIL
check '名前が違えば止める'           '{"DBParameterGroups":[{"DBParameterGroupName":"other","DBParameterGroupFamily":"mysql8.4"}]}' 1 FAIL
check '見つからなければ止める'       '{"DBParameterGroups":[]}' 1 ''

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
