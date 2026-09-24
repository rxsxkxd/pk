#!/usr/bin/env bash
# Step 3（build_green.sh → create_blue_green_deployment.rb）の分岐のテスト。
# AWS へは接続しない（PATH 上の aws を偽物に差し替える）。
#
# 確かめること:
#   - 承認・フェーズ判定（第 1 層）: pending / 切替済み / 不明 で作成へ進まない
#   - Deployment の状態（第 2 層）: AVAILABLE・PROVISIONING は作成せず、使えない状態は止める
#   - 新規作成: 保護スナップショットを確保してから作成し、AVAILABLE を待つ
#   - **変更操作（create-*）を呼んではいけない場面で呼ばない**
set -uo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %-50s %s\n' "$1" "$2"; failed=$((failed + 1)); }

# 設定は staging のものを承認済みにして使う。
config="$work/config.yml"
sed 's/build: pending/build: approved/' config/blue-green/staging.deployment.yml > "$config"
service=example-service
eval "$(ruby scripts/lib/deployment_config.rb vars "$config" "$service" \
  sid=required:service.source_db_instance_identifier \
  sv=required:service.source_engine_version spg=required:service.source_db_parameter_group_name \
  tv=required:service.target_engine_version tpg=required:service.target_db_parameter_group_name)"

# 偽の aws。応答は $fake/ のファイルで決める。
#   phase          フェーズ判定の --query に返す「バージョン<TAB>パラメータグループ」
#   source.json / deployments.json / family / snapshot-status（無ければ NotFound）
#   statuses       --blue-green-deployment-identifier で問い合わせるたびに先頭行から 1 つずつ返す
#   snapshot-error あれば describe-db-snapshots をこの内容で失敗させる
make_fake() {
  fake="$work/fake-$1"; rm -rf "$fake"; mkdir -p "$fake"
  cat > "$fake/aws" <<EOF
#!/bin/sh
d='$fake'
printf '%s\n' "\$*" >> "\$d/calls.log"
case "\$*" in
  *"describe-db-instances"*"--query"*) cat "\$d/phase" ;;
  *describe-db-instances*) cat "\$d/source.json" ;;
  *"describe-blue-green-deployments --filters"*) cat "\$d/deployments.json" ;;
  *"describe-blue-green-deployments --blue-green-deployment-identifier"*)
    s=\$(head -n 1 "\$d/statuses"); sed -i.bak 1d "\$d/statuses"
    [ -n "\$s" ] || s=AVAILABLE
    printf '{"BlueGreenDeployments":[{"Status":"%s"}]}\n' "\$s" ;;
  *describe-db-parameter-groups*) printf '{"DBParameterGroups":[{"DBParameterGroupFamily":"%s"}]}\n' "\$(cat "\$d/family")" ;;
  *"describe-db-snapshots"*)
    if [ -f "\$d/snapshot-error" ]; then cat "\$d/snapshot-error" >&2; exit 254; fi
    if [ ! -f "\$d/snapshot-status" ]; then
      echo 'An error occurred (DBSnapshotNotFound) when calling the DescribeDBSnapshots operation' >&2; exit 254
    fi
    case "\$*" in *--query*) cat "\$d/snapshot-status" ;; *) echo '{"DBSnapshots":[]}' ;; esac ;;
  *create-db-snapshot*) echo available > "\$d/snapshot-status"; echo '{}' ;;
  *"wait db-snapshot-available"*) : ;;
  *create-blue-green-deployment*) echo '{"BlueGreenDeployment":{"BlueGreenDeploymentIdentifier":"bgd-new"}}' ;;
  *) echo "unexpected: \$*" >&2; exit 9 ;;
esac
EOF
  chmod +x "$fake/aws"
  printf '%s\t%s\n' "${sv}.40" "$spg" > "$fake/phase"
  printf '{"DBInstances":[{"DBInstanceArn":"arn:aws:rds:r:1:db:%s","Engine":"mysql","EngineVersion":"8.0.40"}]}\n' "$sid" > "$fake/source.json"
  echo '{"BlueGreenDeployments":[]}' > "$fake/deployments.json"
  echo mysql8.4 > "$fake/family"
  : > "$fake/statuses"
}
existing() {  # $1=Status
  printf '{"BlueGreenDeployments":[{"BlueGreenDeploymentIdentifier":"bgd-old","Status":"%s"}]}\n' "$1" > "$fake/deployments.json"
}

run_build() {
  PATH="$fake:$PATH" bash scripts/build_green.sh --config "$1" --service "$service" \
    --output-dir "$fake/out" >"$fake/stdout" 2>"$fake/stderr"
}
run_create() {
  PATH="$fake:$PATH" ruby scripts/create_blue_green_deployment.rb --config "$config" --service "$service" \
    --output-dir "$fake/out" --poll-interval-seconds 0 >"$fake/stdout" 2>"$fake/stderr"
}

# 終了コードと、呼んだ／呼ばなかった変更操作を確かめる。
expect() {  # $1=説明 $2=実際の終了コード $3=期待 $4=作成を呼ぶか(yes/no) $5=スナップショット作成を呼ぶか $6=出力に含むべき文字列
  local desc=$1 status=$2 want=$3 create=$4 snapshot=$5 message=${6:-}
  local calls; calls=$(cat "$fake/calls.log" 2>/dev/null)
  local called_create=no called_snapshot=no
  [[ "$calls" == *create-blue-green-deployment* ]] && called_create=yes
  [[ "$calls" == *create-db-snapshot* ]] && called_snapshot=yes
  local output; output=$(cat "$fake/stdout" "$fake/stderr")
  if [[ $status -ne $want ]]; then fail "$desc" "終了コード ${status}（期待 ${want}）: ${output:0:200}"
  elif [[ $called_create != "$create" ]]; then fail "$desc" "Blue/Green 作成の呼び出し: ${called_create}（期待 ${create}）"
  elif [[ $called_snapshot != "$snapshot" ]]; then fail "$desc" "スナップショット作成の呼び出し: ${called_snapshot}（期待 ${snapshot}）"
  elif [[ -n "$message" && "$output" != *"$message"* ]]; then fail "$desc" "出力に「${message}」が無い: ${output:0:200}"
  else ok "$desc"
  fi
}

# --- 第 1 層（build_green.sh）---------------------------------------------
make_fake pending
PATH="$fake:$PATH" bash scripts/build_green.sh --config config/blue-green/staging.deployment.yml \
  --service "$service" --output-dir "$fake/out" >"$fake/stdout" 2>"$fake/stderr"
st=$?; [[ -f "$fake/calls.log" ]] && fail 'pending: AWS を呼ばない' "$(cat "$fake/calls.log")" || expect 'pending: 何もせず成功' $st 0 no no 'no changes made'

make_fake post
printf '%s\t%s\n' "$tv" "$tpg" > "$fake/phase"
run_build "$config"; expect '切替済み: 作成へ進まない' $? 0 no no 'Migration already completed'

make_fake unknown
printf '%s\t%s\n' 5.7.44 other-pg > "$fake/phase"
run_build "$config"; expect 'フェーズ不明: 止める' $? 1 no no 'いずれの宣言とも一致しない'

# --- 第 2 層: 既存 Deployment ------------------------------------------------
make_fake available; existing AVAILABLE
run_build "$config"; expect '既存 AVAILABLE: 作成しない' $? 0 no no 'already available: bgd-old'

make_fake provisioning; existing PROVISIONING; printf 'PROVISIONING\nAVAILABLE\n' > "$fake/statuses"
run_create; expect '既存 PROVISIONING: 作成せず AVAILABLE を待つ' $? 0 no no 'Deployment identifier: bgd-old'

make_fake provisioning-fails; existing PROVISIONING; printf 'PROVISIONING\nINVALID_CONFIGURATION\n' > "$fake/statuses"
run_create; expect '既存 PROVISIONING → 失敗: 止める' $? 1 no no 'did not become available'

make_fake invalid; existing INVALID_CONFIGURATION
run_build "$config"; expect '既存 INVALID_CONFIGURATION: 作成せず止める' $? 1 no no 'not usable: bgd-old'

# --- 新規作成 --------------------------------------------------------------
make_fake new
run_build "$config"; expect '新規: スナップショット → 作成 → AVAILABLE' $? 0 yes yes 'Created Blue/Green Deployment: bgd-new'
# 順序: 保護スナップショットの確保（作成と available 待ち）が Blue/Green の作成より先であること。
order=$(grep -nE 'create-db-snapshot|wait db-snapshot-available|create-blue-green-deployment' "$fake/calls.log" | cut -d: -f1 | tr '\n' ' ')
read -r a b c <<< "$order"
[[ -n "${c:-}" && $a -lt $b && $b -lt $c ]] && ok '新規: スナップショットを確保してから作成する' || fail '新規: 呼び出し順' "$order"
for file in source-db-instance.json deployments.json target-db-parameter-group.json create-snapshot.json snapshot.json \
            create-blue-green-deployment.json describe-blue-green-deployment.json; do
  [[ -f "$fake/out/$file" ]] || fail "新規: $file を保存する" '無い'
done

make_fake snapshot-exists; echo available > "$fake/snapshot-status"
run_build "$config"; expect '新規・スナップショット既存: 作り直さない' $? 0 yes no 'Protection snapshot is available'

make_fake snapshot-creating; echo creating > "$fake/snapshot-status"
run_build "$config"; expect '新規・スナップショット作成中: 待ってから作成' $? 0 yes no 'Protection snapshot is creating'

make_fake snapshot-failed; echo failed > "$fake/snapshot-status"
run_build "$config"; expect '新規・スナップショット failed: 作成しない' $? 1 no no 'unusable state'

make_fake snapshot-denied; echo 'An error occurred (AccessDenied) when calling the DescribeDBSnapshots operation' > "$fake/snapshot-error"
run_build "$config"; expect '新規・スナップショット確認で権限不足: 作成しない' $? 1 no no 'AccessDenied'

make_fake family; echo mysql8.0 > "$fake/family"
run_build "$config"; expect '新規・パラメータグループが 8.4 でない: 作成しない' $? 1 no no 'family must be mysql8.4'

make_fake not80
printf '{"DBInstances":[{"DBInstanceArn":"arn:aws:rds:r:1:db:x","Engine":"mysql","EngineVersion":"5.7.44"}]}\n' > "$fake/source.json"
run_create; expect '新規・移行元が 8.0 でない: 作成しない' $? 1 no no 'must be MySQL 8.0'

make_fake new-fails; printf 'PROVISIONING\nINVALID_CONFIGURATION\n' > "$fake/statuses"
run_create; expect '新規作成後に失敗: 止める' $? 1 yes yes 'did not become available'

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
