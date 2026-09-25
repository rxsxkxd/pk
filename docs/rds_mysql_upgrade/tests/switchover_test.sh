#!/usr/bin/env bash
# Step 5（switchover.sh → switchover_blue_green_deployment.rb）の分岐のテスト。
# AWS へは接続しない（PATH 上の aws を偽物に差し替える）。
#
# 確かめること:
#   - 承認・フェーズ判定（第 1 層）: pending / 切替済み / 不明 では切り替えない
#   - Deployment の状態（第 2 層）: AVAILABLE だけを切り替え、進行中なら二重に呼ばず待つ
#   - 切替完了（SWITCHOVER_COMPLETED）まで待ち、そうならなければ失敗する
#   - **変更操作（switchover-blue-green-deployment）を呼んではいけない場面で呼ばない**
set -uo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %-50s %s\n' "$1" "$2"; failed=$((failed + 1)); }

config="$work/config.yml"
sed 's/switchover: pending/switchover: approved/' config/blue-green/staging.deployment.yml > "$config"
service=example-service
vars=$(ruby scripts/lib/deployment_config.rb vars "$config" "$service" \
  sid=required:service.source_db_instance_identifier \
  sv=required:service.source_engine_version spg=required:service.source_db_parameter_group_name \
  tv=required:service.target_engine_version tpg=required:service.target_db_parameter_group_name)
eval "$vars"

# 偽の aws。source.json と deployments.json で状態を決め、
# --blue-green-deployment-identifier の問い合わせには statuses の先頭行から 1 つずつ返す。
make_fake() {
  fake="$work/fake-$1"; rm -rf "$fake"; mkdir -p "$fake"
  cat > "$fake/aws" <<FAKE
#!/bin/sh
d='$fake'
printf '%s\n' "\$*" >> "\$d/calls.log"
case "\$*" in
  *describe-db-instances*) cat "\$d/source.json" ;;
  *"describe-blue-green-deployments --filters"*) cat "\$d/deployments.json" ;;
  *"describe-blue-green-deployments --blue-green-deployment-identifier"*)
    s=\$(head -n 1 "\$d/statuses"); sed -i.bak 1d "\$d/statuses"
    [ -n "\$s" ] || s=SWITCHOVER_COMPLETED
    printf '{"BlueGreenDeployments":[{"Status":"%s"}]}\n' "\$s" ;;
  *switchover-blue-green-deployment*) echo '{"BlueGreenDeployment":{"Status":"SWITCHOVER_IN_PROGRESS"}}' ;;
  *) echo "unexpected: \$*" >&2; exit 9 ;;
esac
FAKE
  chmod +x "$fake/aws"
  set_source "${sv}.40" "$spg"
  deployment AVAILABLE
  : > "$fake/statuses"
}
set_source() { printf '{"DBInstances":[{"DBInstanceArn":"arn:src","EngineVersion":"%s","DBParameterGroups":[{"DBParameterGroupName":"%s"}]}]}\n' "$1" "$2" > "$fake/source.json"; }
deployment() {  # $1=Status（空なら Deployment 無し）
  if [[ -z "$1" ]]; then echo '{"BlueGreenDeployments":[]}' > "$fake/deployments.json"
  else printf '{"BlueGreenDeployments":[{"BlueGreenDeploymentIdentifier":"bgd-1","Status":"%s"}]}\n' "$1" > "$fake/deployments.json"; fi
}
run_switchover() {
  PATH="$fake:$PATH" bash scripts/switchover.sh --config "${1:-$config}" --service "$service" --approve \
    --output-dir "$fake/out" >"$fake/stdout" 2>"$fake/stderr"
}
run_rb() {  # 待機を伴うケースは間隔 0 で直接呼ぶ
  PATH="$fake:$PATH" ruby scripts/switchover_blue_green_deployment.rb --config "$config" --service "$service" --approve \
    --output-dir "$fake/out" --poll-interval-seconds 0 >"$fake/stdout" 2>"$fake/stderr"
}
expect() {  # $1=説明 $2=終了コード $3=期待 $4=切替を呼ぶか(yes/no) $5=出力に含むべき文字列
  local desc=$1 status=$2 want=$3 switched=$4 message=$5
  local called=no; grep -q 'switchover-blue-green-deployment' "$fake/calls.log" 2>/dev/null && called=yes
  local output; output=$(cat "$fake/stdout" "$fake/stderr")
  if [[ $status -ne $want ]]; then fail "$desc" "終了コード ${status}（期待 ${want}）: ${output:0:200}"
  elif [[ $called != "$switched" ]]; then fail "$desc" "切替の呼び出し: ${called}（期待 ${switched}）"
  elif [[ "$output" != *"$message"* ]]; then fail "$desc" "出力に「${message}」が無い: ${output:0:200}"
  else ok "$desc"; fi
}

make_fake pending
run_switchover config/blue-green/staging.deployment.yml; st=$?
[[ -f "$fake/calls.log" ]] && fail 'pending: AWS を呼ばない' "$(cat "$fake/calls.log")" || expect 'pending: 何もせず成功' $st 0 no 'no changes made'

make_fake post; set_source "$tv" "$tpg"
run_switchover; expect '切替済み: 何もせず成功' $? 0 no 'Switchover already completed'

make_fake unknown; set_source 5.7.44 other
run_switchover; expect 'フェーズ不明: 止める' $? 1 no 'いずれの宣言とも一致しない'

make_fake available
run_switchover; expect 'AVAILABLE: 切り替えて完了を確認する' $? 0 yes 'Switchover completed: bgd-1'
grep -q -- '--switchover-timeout 300' "$fake/calls.log" && ok 'RDS へ渡す切替タイムアウトは設定の値（既定 300）' \
  || fail '切替タイムアウト' "$(grep switchover-blue-green "$fake/calls.log")"

make_fake in-progress; deployment SWITCHOVER_IN_PROGRESS; printf 'SWITCHOVER_IN_PROGRESS\nSWITCHOVER_COMPLETED\n' > "$fake/statuses"
run_rb; expect '進行中: 二重に切り替えず完了を待つ' $? 0 no 'Switchover completed: bgd-1'

make_fake fails; printf 'SWITCHOVER_IN_PROGRESS\nSWITCHOVER_FAILED\n' > "$fake/statuses"
run_rb; expect '切替が失敗に終われば止める' $? 1 yes 'Switchover did not complete; status: SWITCHOVER_FAILED'

make_fake invalid; deployment INVALID_CONFIGURATION
run_switchover; expect 'AVAILABLE 以外: 切り替えず止める' $? 1 no 'requires AVAILABLE status'

make_fake none; deployment ''
run_switchover; expect 'Deployment が無い: 止める' $? 1 no 'Blue/Green Deployment not found'

make_fake no-approve
PATH="$fake:$PATH" ruby scripts/switchover_blue_green_deployment.rb --config "$config" --service "$service" >"$fake/stdout" 2>"$fake/stderr"
expect '--approve が無ければ使い方の誤り' $? 2 no '--approve is required'

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
