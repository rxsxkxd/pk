#!/usr/bin/env bash
# Step 4（verify_green.sh → prepare_green_verification.rb → Go の判定器）の通しのテスト。
# AWS へも DB へも接続しない（aws と実効値の収集バイナリを偽物に差し替える）。
#
# 確かめること:
#   - 切替済みなら検証対象なしで成功し、レポートを作らない
#   - 設定どおりなら VERIFY PASSED、宣言値とずれれば終了コード 1 で理由を出す
#   - MySQL 実効値: 無効なら「未収集」、有効なら収集した値、--runtime-values-file ならその値
#   - Deployment が無ければ止まる
# Go が未導入の環境ではスキップする（判定器をその場でビルドするため）。
set -uo pipefail
cd "$(dirname "$0")/.."
command -v go >/dev/null 2>&1 || { echo 'skip  Go（未導入）'; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %-44s %s\n' "$1" "$2"; failed=$((failed + 1)); }
export GREEN_TOOLS_BUILD_DIR="$work/built"   # 判定器のビルド先（リポジトリの .tools を汚さない）
C=$PWD/examples/cfn-shorthand/collected

# 設定: staging を元に、テンプレートを fixture（C の収集結果と一致するもの）へ差し替える。
config="$work/config.yml"
sed 's#target_parameter_group_template_path: .*#target_parameter_group_template_path: examples/cfn-shorthand/mysql84-parameter-group-shorthand.yaml#' \
  config/blue-green/staging.deployment.yml > "$config"
vars=$(ruby scripts/lib/deployment_config.rb vars "$config" example-service \
  sid=required:service.source_db_instance_identifier sv=required:service.source_engine_version \
  spg=required:service.source_db_parameter_group_name tv=required:service.target_engine_version \
  tc=required:service.target_db_instance_class tpg=required:service.target_db_parameter_group_name)
eval "$vars"

# 偽の aws。移行元（phase）・Deployment・Green のクラスをファイルで変えられる。
make_fake() {
  fake="$work/fake-$1"; rm -rf "$fake"; mkdir -p "$fake"
  printf '%s\t%s\n' "${sv}.44" "$spg" > "$fake/source"
  printf '{"BlueGreenDeployments":[{"BlueGreenDeploymentIdentifier":"bgd-1","Target":"arn:aws:rds:r:1:db:green-1","Status":"AVAILABLE"}]}\n' > "$fake/deployments.json"
  echo "$tc" > "$fake/class"
  cat > "$fake/aws" <<FAKE
#!/bin/sh
d='$fake'
case "\$*" in
  *"--db-instance-identifier $sid "*)
    read -r v g < "\$d/source"
    printf '{"DBInstances":[{"DBInstanceArn":"arn:src","EngineVersion":"%s","DBParameterGroups":[{"DBParameterGroupName":"%s"}]}]}\n' "\$v" "\$g" ;;
  *describe-blue-green-deployments*) cat "\$d/deployments.json" ;;
  *"--db-instance-identifier green-1"*)
    ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); i=d["DBInstances"][0]; i["EngineVersion"]=ARGV[1]; i["DBInstanceClass"]=ARGV[2]; i["DBParameterGroups"]=[{"DBParameterGroupName"=>ARGV[3],"ParameterApplyStatus"=>"in-sync"}]; i["Endpoint"]={"Address"=>"green-1.example"}; puts d.to_json' "$C/green-db-instance.json" "$tv" "\$(cat "\$d/class")" "$tpg" ;;
  *"--source user"*) cat "$C/green-user-parameters.json" ;;
  *"--source system"*) cat "$C/green-system-parameters.json" ;;
  *describe-db-parameters*) cat "$C/green-all-parameters.json" ;;
  *get-metric-statistics*) cat "$C/replica-lag.json" ;;
  *) echo "unexpected: \$*" >&2; exit 9 ;;
esac
FAKE
  chmod +x "$fake/aws"
}
run() {  # $1=設定 残り=追加引数
  local cfg=$1; shift
  PATH="$fake:$PATH" bash scripts/verify_green.sh --config "$cfg" --service example-service \
    --output-dir "$fake/out" "$@" >"$fake/stdout" 2>"$fake/stderr"
}
expect() {  # $1=説明 $2=終了コード $3=期待 $4=出力に含むべき文字列
  local output; output=$(cat "$fake/stdout" "$fake/stderr")
  if [[ $2 -ne $3 ]]; then fail "$1" "終了コード $2（期待 $3）: ${output:0:300}"
  elif [[ "$output" != *"$4"* ]]; then fail "$1" "出力に「$4」が無い: ${output:0:300}"
  else ok "$1"; fi
}
report() { cat "$fake/out/green-verification-report.md" 2>/dev/null; }

make_fake post; printf '%s\t%s\n' "$tv" "$tpg" > "$fake/source"
run "$config"; expect '切替済み: 検証対象なしで成功' $? 0 'Already switched over'
[[ ! -f "$fake/out/green-verification-report.md" ]] && ok '切替済み: レポートを作らない' || fail '切替済み: レポート' 'ある'

make_fake pass
run "$config"; expect '設定どおり: VERIFY PASSED' $? 0 'VERIFY PASSED: bgd-1'
[[ "$(report)" == *'| 未収集 |'* ]] && ok 'MySQL 無効: 実効値は「未収集」' || fail 'MySQL 無効' "$(report | head -3)"

make_fake class; echo db.r6g.large > "$fake/class"
run "$config"; expect 'クラスがずれれば止める' $? 1 '不適合: Green のインスタンスクラス'

make_fake file
run "$config" --runtime-values-file "$C/green-runtime-values.json"; expect '--runtime-values-file: 渡した値を使う' $? 0 'VERIFY PASSED'
[[ "$(report)" != *'| 未収集 |'* ]] && ok '--runtime-values-file: 実効値の列が埋まる' || fail '--runtime-values-file' '未収集のまま'

make_fake mysql
ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); m=d["services"]["example-service"]["mysql_verification"]; m.merge!("enabled"=>true,"auth_method"=>"plaintext","user"=>"verifier","password"=>"pt"); File.write(ARGV[1], d.to_yaml)' "$config" "$work/mysql.yml"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --output ] && cp "%s/green-runtime-values.json" "$2"; shift; done\n' "$C" > "$work/collector"
chmod +x "$work/collector"
GREEN_RUNTIME_COLLECTOR="$work/collector" run "$work/mysql.yml"; expect 'MySQL 有効: 収集して検証する' $? 0 'mysql_verification.enabled=true auth_method=plaintext'
[[ "$(report)" != *'| 未収集 |'* ]] && ok 'MySQL 有効: 実効値の列が埋まる' || fail 'MySQL 有効' '未収集のまま'
grep -q '^VERIFY=\|^DEPLOYMENT_ID=\|^TEMPLATE=' "$fake/stdout" && fail '準備の代入行が標準出力へ漏れていない' "$(cat "$fake/stdout")" || ok '準備の代入行は標準出力へ漏れない'

make_fake none; echo '{"BlueGreenDeployments":[]}' > "$fake/deployments.json"
run "$config"; expect 'Deployment が無ければ止める' $? 1 'Blue/Green Deployment not found'

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
