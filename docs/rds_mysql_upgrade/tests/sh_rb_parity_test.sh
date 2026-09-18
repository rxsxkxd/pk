#!/usr/bin/env bash
# シェル版と Ruby 版が同じ振る舞いをすることを確認する。AWS へは接続しない。
#
# scripts/ 配下のうち、buildspec から直接呼ばれない 3 本を Ruby へ置き換えた。
# **シェル版も残してあるので、両方が同じ結論を出し続けることをここで固定する。**
#   create_blue_green_deployment      .sh / .rb
#   switchover_blue_green_deployment  .sh / .rb
#   collect_green_runtime_values      .sh / .rb
#
# AWS CLI はスタブへ差し替える。呼び出し引数を記録し、固定の JSON を返す。
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0

compare() {  # 同じ入力で sh と rb の終了コードを比べる
  local desc=$1; shift
  local sh_status rb_status
  "$@" >/dev/null 2>&1; sh_status=$?
  shift_args=("$@")
  if [[ "$sh_status" -eq "$RB_STATUS" ]]; then
    printf 'ok    %-52s exit=%s（一致）\n' "$desc" "$sh_status"
  else
    printf 'FAIL  %-52s sh=%s rb=%s\n' "$desc" "$sh_status" "$RB_STATUS"
    failed=$((failed + 1))
  fi
}

run_pair() {  # $1=説明 $2=sh のパス $3=rb のパス 以降=共通引数
  local desc=$1 sh_path=$2 rb_path=$3; shift 3
  local sh_out rb_out sh_status rb_status
  sh_out=$(bash "$sh_path" "$@" 2>&1); sh_status=$?
  rb_out=$(ruby "$rb_path" "$@" 2>&1); rb_status=$?
  if [[ "$sh_status" -eq "$rb_status" ]]; then
    printf 'ok    %-54s exit=%s\n' "$desc" "$sh_status"
  else
    printf 'FAIL  %-54s sh=%s rb=%s\n' "$desc" "$sh_status" "$rb_status"
    printf '      sh: %s\n      rb: %s\n' "${sh_out:0:120}" "${rb_out:0:120}"
    failed=$((failed + 1))
  fi
}

if ! command -v ruby >/dev/null 2>&1; then echo 'skip  Ruby が見つからない'; exit 0; fi

# --- 設定ファイル -----------------------------------------------------------
cat > "$work/config.yml" <<'YAML'
environment: staging
aws_region: ap-northeast-1
services:
  svc:
    source_db_instance_identifier: blue-mysql80
    target_engine_version: 8.4.10
    target_db_instance_class: db.t4g.medium
    target_db_parameter_group_name: pg-mysql84
YAML

# --- 引数エラー（AWS へ到達しない経路）--------------------------------------
run_pair '引数なし: create' scripts/create_blue_green_deployment.sh scripts/create_blue_green_deployment.rb
run_pair '--service だけ: create' scripts/create_blue_green_deployment.sh scripts/create_blue_green_deployment.rb --service svc
run_pair '整数でない待機時間: create' scripts/create_blue_green_deployment.sh scripts/create_blue_green_deployment.rb \
  --config "$work/config.yml" --service svc --wait-timeout-seconds abc
run_pair '--help: create' scripts/create_blue_green_deployment.sh scripts/create_blue_green_deployment.rb --help

run_pair '引数なし: switchover' scripts/switchover_blue_green_deployment.sh scripts/switchover_blue_green_deployment.rb
run_pair '--approve 無し: switchover' scripts/switchover_blue_green_deployment.sh scripts/switchover_blue_green_deployment.rb \
  --config "$work/config.yml" --blue-green-deployment-id bgd-1
run_pair '整数でないタイムアウト: switchover' scripts/switchover_blue_green_deployment.sh scripts/switchover_blue_green_deployment.rb \
  --config "$work/config.yml" --blue-green-deployment-id bgd-1 --approve --switchover-timeout abc
run_pair '--help: switchover' scripts/switchover_blue_green_deployment.sh scripts/switchover_blue_green_deployment.rb --help

run_pair '引数なし: collect' scripts/collect_green_runtime_values.sh scripts/collect_green_runtime_values.rb
run_pair '--help: collect' scripts/collect_green_runtime_values.sh scripts/collect_green_runtime_values.rb --help

# --- 設定の不備 -------------------------------------------------------------
run_pair '設定ファイルが無い: create' scripts/create_blue_green_deployment.sh scripts/create_blue_green_deployment.rb \
  --config "$work/absent.yml" --service svc
run_pair '未知のサービス: create' scripts/create_blue_green_deployment.sh scripts/create_blue_green_deployment.rb \
  --config "$work/config.yml" --service nosuch

# --- AWS CLI をスタブにして、変更操作の呼び出し引数を比べる -------------------
mkdir -p "$work/bin"
cat > "$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
# 呼び出し引数を記録し、固定の応答を返すスタブ。--region などの前置きは落として記録する。
printf '%s\n' "$*" | sed 's/--region [^ ]* //; s/--profile [^ ]* //' >> "$AWS_STUB_LOG"

# シェル版は同じ API を --query ... --output text でもう一度叩く。
# Ruby 版は JSON を 1 回だけ取って自前で取り出すため、この分岐は sh 側でのみ通る。
case "$*" in
  *"--output text"*)
    case "$*" in
      *"BlueGreenDeployments[0].Status"*) echo 'AVAILABLE' ;;
      *"DBInstances[0].[Engine,EngineVersion,DBInstanceArn]"*)
        printf 'mysql\t8.0.39\tarn:aws:rds:ap-northeast-1:1:db:blue\n' ;;
      *"DBParameterGroups[0].DBParameterGroupFamily"*) echo 'mysql8.4' ;;
      *) echo 'None' ;;
    esac
    exit 0 ;;
esac

case "$*" in
  *describe-blue-green-deployments*)
    echo '{"BlueGreenDeployments":[{"Status":"AVAILABLE","BlueGreenDeploymentIdentifier":"bgd-1","Target":"arn:aws:rds:ap-northeast-1:1:db:green"}]}' ;;
  *switchover-blue-green-deployment*)
    echo '{"BlueGreenDeployment":{"Status":"SWITCHOVER_IN_PROGRESS"}}' ;;
  *describe-db-instances*)
    echo '{"DBInstances":[{"Engine":"mysql","EngineVersion":"8.0.39","DBInstanceArn":"arn:aws:rds:ap-northeast-1:1:db:blue"}]}' ;;
  *describe-db-parameter-groups*)
    echo '{"DBParameterGroups":[{"DBParameterGroupFamily":"mysql8.4"}]}' ;;
  *create-blue-green-deployment*)
    echo '{"BlueGreenDeployment":{"BlueGreenDeploymentIdentifier":"bgd-1"}}' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$work/bin/aws"

stub_run() {  # $1=ログ $2=実行するもの 以降=引数
  local log=$1; shift
  : > "$log"
  AWS_STUB_LOG="$log" PATH="$work/bin:$PATH" "$@" >/dev/null 2>&1
  echo $?
}

# switchover: 変更操作まで到達する経路
sh_status=$(stub_run "$work/sw-sh.log" bash scripts/switchover_blue_green_deployment.sh \
  --config "$work/config.yml" --blue-green-deployment-id bgd-1 --approve --output-dir "$work/sw-sh")
rb_status=$(stub_run "$work/sw-rb.log" ruby scripts/switchover_blue_green_deployment.rb \
  --config "$work/config.yml" --blue-green-deployment-id bgd-1 --approve --output-dir "$work/sw-rb")
if [[ "$sh_status" -eq 0 && "$rb_status" -eq 0 ]]; then
  echo 'ok    switchover: どちらも成功する'
else
  echo "FAIL  switchover: sh=$sh_status rb=$rb_status"; failed=$((failed + 1))
fi
if diff <(grep switchover-blue-green "$work/sw-sh.log") <(grep switchover-blue-green "$work/sw-rb.log") >/dev/null; then
  echo 'ok    switchover: 変更操作の呼び出し引数が一致する'
else
  echo 'FAIL  switchover: 変更操作の引数が違う'
  diff <(cat "$work/sw-sh.log") <(cat "$work/sw-rb.log") | head -10
  failed=$((failed + 1))
fi
for name in before-switchover.json switchover-blue-green-deployment.json; do
  if [[ -f "$work/sw-sh/$name" && -f "$work/sw-rb/$name" ]] && diff "$work/sw-sh/$name" "$work/sw-rb/$name" >/dev/null; then
    printf 'ok    switchover: %s が一致する\n' "$name"
  else
    printf 'FAIL  switchover: %s が違う／無い\n' "$name"; failed=$((failed + 1))
  fi
done

# create: AVAILABLE を即返すので待機ループを 1 周で抜ける
sh_status=$(stub_run "$work/cr-sh.log" bash scripts/create_blue_green_deployment.sh \
  --config "$work/config.yml" --service svc --deployment-name fixed-name --output-dir "$work/cr-sh")
rb_status=$(stub_run "$work/cr-rb.log" ruby scripts/create_blue_green_deployment.rb \
  --config "$work/config.yml" --service svc --deployment-name fixed-name --output-dir "$work/cr-rb")
if [[ "$sh_status" -eq 0 && "$rb_status" -eq 0 ]]; then
  echo 'ok    create: どちらも成功する'
else
  echo "FAIL  create: sh=$sh_status rb=$rb_status"; failed=$((failed + 1))
fi
if diff <(grep create-blue-green "$work/cr-sh.log") <(grep create-blue-green "$work/cr-rb.log") >/dev/null; then
  echo 'ok    create: 変更操作の呼び出し引数が一致する'
else
  echo 'FAIL  create: 変更操作の引数が違う'
  diff <(grep create-blue-green "$work/cr-sh.log") <(grep create-blue-green "$work/cr-rb.log") | head -10
  failed=$((failed + 1))
fi
for name in source-db-instance.json target-db-parameter-group.json create-blue-green-deployment.json; do
  if [[ -f "$work/cr-sh/$name" && -f "$work/cr-rb/$name" ]] && diff "$work/cr-sh/$name" "$work/cr-rb/$name" >/dev/null; then
    printf 'ok    create: %s が一致する\n' "$name"
  else
    printf 'FAIL  create: %s が違う／無い\n' "$name"; failed=$((failed + 1))
  fi
done

# --- 呼び出し側が .rb を指していること ---------------------------------------
check_switch() {
  local caller=$1 target=$2
  if grep -q "$target" "$caller"; then
    printf 'ok    %s が %s を呼ぶ\n' "$(basename "$caller")" "$target"
  else
    printf 'FAIL  %s が %s を呼んでいない\n' "$(basename "$caller")" "$target"; failed=$((failed + 1))
  fi
}
check_switch scripts/build_green.sh create_blue_green_deployment.rb
check_switch scripts/switchover.sh switchover_blue_green_deployment.rb
check_switch scripts/verify_green.sh collect_green_runtime_values.rb

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
