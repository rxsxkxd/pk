#!/usr/bin/env bash
# deployment_config.sh（設定 YAML の読み取り）のテスト。AWS へは接続しない。
# 実行: tests/deployment_config_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../scripts/lib/deployment_config.sh
source scripts/lib/deployment_config.sh

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failed=0

cat > "$tmp/full.yml" <<'YAML'
environment: staging
aws_region: ap-northeast-1
aws_profile: my-profile
services:
  svc:
    source_db_instance_identifier: blue-mysql80
    protection_snapshot_identifier: blue pre-bg'$(echo injected)
    actions:
      build: approved
      switchover_timeout: 600
YAML

cat > "$tmp/min.yml" <<'YAML'
aws_region: ap-northeast-1
services:
  svc:
    source_db_instance_identifier: blue-mysql80
YAML

# 成功を期待する。第 3 引数以降は "変数名=期待値"。
expect_ok() {
  local desc=$1 config=$2 filter=$3; shift 3
  local output
  if ! output=$(deployment_config_vars "$config" svc "$filter" 2>"$tmp/err"); then
    printf 'FAIL  %-52s 失敗した: %s\n' "$desc" "$(cat "$tmp/err")"; failed=$((failed + 1)); return
  fi
  # 呼び出し側と同じく eval してから値を確かめる。
  local bad=''
  ( eval "$output"
    for pair in "$@"; do
      k=${pair%%=*}; v=${pair#*=}
      [[ "${!k:-}" == "$v" ]] || { printf '%s=%s(期待 %s) ' "$k" "${!k:-}" "$v"; }
    done ) > "$tmp/bad"
  bad=$(cat "$tmp/bad")
  if [[ -z "$bad" ]]; then printf 'ok    %s\n' "$desc"
  else printf 'FAIL  %-52s %s\n' "$desc" "$bad"; failed=$((failed + 1)); fi
}

# 失敗を期待する。第 4 引数はエラーメッセージに含まれるべき文字列。
expect_ng() {
  local desc=$1 config=$2 filter=$3 want=$4 service=${5:-svc}
  if deployment_config_vars "$config" "$service" "$filter" >/dev/null 2>"$tmp/err"; then
    printf 'FAIL  %-52s 通ってしまった\n' "$desc"; failed=$((failed + 1)); return
  fi
  local out; out=$(cat "$tmp/err")
  if [[ "$out" == *"$want"* ]]; then printf 'ok    %-52s → %s\n' "$desc" "${out%%$'\n'*}"
  else printf 'FAIL  %-52s メッセージ不一致: %s\n' "$desc" "$out"; failed=$((failed + 1)); fi
}

expect_ok '必須項目を取り出す' "$tmp/full.yml" \
  'service($service) as $svc | {
     region: required("aws_region"; .aws_region),
     source_id: required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
   } | shellvars' \
  region=ap-northeast-1 source_id=blue-mysql80

expect_ok '任意項目は既定値へ倒す' "$tmp/min.yml" \
  'service($service) as $svc | {
     build: optional($svc.actions.build; "pending"),
     profile: optional(.aws_profile; ""),
     timeout: optional($svc.actions.switchover_timeout; 300),
   } | shellvars' \
  build=pending profile= timeout=300

expect_ok '任意項目に値があればそれを使う' "$tmp/full.yml" \
  'service($service) as $svc | {
     build: optional($svc.actions.build; "pending"),
     profile: optional(.aws_profile; ""),
     timeout: optional($svc.actions.switchover_timeout; 300),
   } | shellvars' \
  build=approved profile=my-profile timeout=600

# シェルのメタ文字を含む値でもコマンド置換が起きない（@sh のクォート）。
expect_ok '記号を含む値を安全にクォートする' "$tmp/full.yml" \
  'service($service) as $svc | {snapshot: $svc.protection_snapshot_identifier} | shellvars' \
  "snapshot=blue pre-bg'\$(echo injected)"

expect_ng '必須項目の欠落を検出する' "$tmp/min.yml" \
  'service($service) as $svc | {x: required("services.svc.absent"; $svc.absent)} | shellvars' \
  'services.svc.absent が未定義である'

expect_ng '空文字も未定義として扱う' "$tmp/min.yml" \
  'service($service) as $svc | {x: required("aws_profile"; .aws_profile)} | shellvars' \
  'aws_profile が未定義である'

expect_ng '未知のサービス名を検出する' "$tmp/min.yml" \
  'service($service) | {} | shellvars' \
  'services.nosuch が未定義である' nosuch

expect_ng '読めない設定ファイルを検出する' "$tmp/absent.yml" \
  '{} | shellvars' 'YAML を読み込めなかった'

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
