#!/usr/bin/env bash
# deployment_config.rb（設定 YAML の読み取り）のテスト。AWS へは接続しない。
# シェルの呼び出し元と同じく、コマンドとして呼んで代入行を eval する。
# 実行: tests/deployment_config_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
reader=(ruby scripts/lib/deployment_config.rb)

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
    mysql_verification:
      enabled: true
YAML

cat > "$tmp/min.yml" <<'YAML'
aws_region: ap-northeast-1
services:
  svc:
    source_db_instance_identifier: blue-mysql80
YAML

printf 'aws_region: [unterminated\n' > "$tmp/broken.yml"

# 成功を期待する。"--" より前が項目の宣言、後ろが "変数名=期待値"。
expect_ok() {
  local desc=$1 config=$2; shift 2
  local specs=()
  while [[ $1 != -- ]]; do specs+=("$1"); shift; done; shift
  local output
  if ! output=$("${reader[@]}" vars "$config" svc "${specs[@]}" 2>"$tmp/err"); then
    printf 'FAIL  %-52s 失敗した: %s\n' "$desc" "$(cat "$tmp/err")"; failed=$((failed + 1)); return
  fi
  # 呼び出し側と同じく eval してから値を確かめる。
  local bad
  bad=$( eval "$output"
    for pair in "$@"; do
      k=${pair%%=*}; v=${pair#*=}
      [[ "${!k:-}" == "$v" ]] || printf '%s=%s(期待 %s) ' "$k" "${!k:-}" "$v"
    done )
  if [[ -z "$bad" ]]; then printf 'ok    %s\n' "$desc"
  else printf 'FAIL  %-52s %s\n' "$desc" "$bad"; failed=$((failed + 1)); fi
}

# 失敗を期待する。第 2 引数は期待する終了コード、第 3 引数はエラーメッセージに含まれるべき文字列。
expect_ng() {
  local desc=$1 want_status=$2 want=$3 config=$4 service=$5; shift 5
  "${reader[@]}" vars "$config" "$service" "$@" >/dev/null 2>"$tmp/err"
  local status=$? out; out=$(cat "$tmp/err")
  if [[ $status -ne $want_status ]]; then
    printf 'FAIL  %-52s 終了コード %s（期待 %s）: %s\n' "$desc" "$status" "$want_status" "$out"; failed=$((failed + 1))
  elif [[ "$out" == *"$want"* ]]; then printf 'ok    %-52s → %s\n' "$desc" "${out%%$'\n'*}"
  else printf 'FAIL  %-52s メッセージ不一致: %s\n' "$desc" "$out"; failed=$((failed + 1)); fi
}

expect_ok '必須項目を取り出す（トップレベルとサービス配下）' "$tmp/full.yml" \
  region=required:aws_region source_id=required:service.source_db_instance_identifier -- \
  region=ap-northeast-1 source_id=blue-mysql80

expect_ok '任意項目は既定値へ倒す' "$tmp/min.yml" \
  build=optional:service.actions.build=pending profile=optional:aws_profile \
  timeout=optional:service.actions.switchover_timeout=300 -- \
  build=pending profile= timeout=300

expect_ok '任意項目に値があればそれを使う（数値も文字列になる）' "$tmp/full.yml" \
  build=optional:service.actions.build=pending profile=optional:aws_profile \
  timeout=optional:service.actions.switchover_timeout=300 -- \
  build=approved profile=my-profile timeout=600

expect_ok 'flag は true / false の文字列にする（未定義は false）' "$tmp/full.yml" \
  on=flag:service.mysql_verification.enabled off=flag:service.mysql_verification.absent -- \
  on=true off=false

expect_ok '途中がマッピングでないパスは未定義として扱う' "$tmp/full.yml" \
  x=optional:service.source_db_instance_identifier.deeper=fallback -- \
  x=fallback

# シェルのメタ文字を含む値でもコマンド置換が起きない（単一引用符でクォートする）。
expect_ok '記号を含む値を安全にクォートする' "$tmp/full.yml" \
  snapshot=required:service.protection_snapshot_identifier -- \
  "snapshot=blue pre-bg'\$(echo injected)"

expect_ok 'サービス名が空でもトップレベルだけなら読める' "$tmp/min.yml" \
  region=required:aws_region -- region=ap-northeast-1

expect_ng '必須項目の欠落を検出する' 1 'services.svc.absent が未定義である' \
  "$tmp/min.yml" svc x=required:service.absent

expect_ng '空文字も未定義として扱う' 1 'aws_profile が未定義である' \
  "$tmp/min.yml" svc x=required:aws_profile

expect_ng '未知のサービス名を検出する' 1 'services.nosuch が未定義である' \
  "$tmp/min.yml" nosuch x=required:service.source_db_instance_identifier

expect_ng '読めない設定ファイルを検出する' 1 'YAML を読み込めなかった' \
  "$tmp/absent.yml" svc x=required:aws_region

expect_ng '壊れた YAML を検出する' 1 'YAML を解析できなかった' \
  "$tmp/broken.yml" svc x=required:aws_region

expect_ng '不正な変数名は使い方の誤り' 2 '変数名が不正' \
  "$tmp/min.yml" svc 'bad-name=required:aws_region'

expect_ng '未知の種別は使い方の誤り' 2 '項目の宣言を解釈できない' \
  "$tmp/min.yml" svc 'x=mandatory:aws_region'

expect_ng 'required に既定値は付けられない' 2 '既定値を持てるのは optional だけ' \
  "$tmp/min.yml" svc 'x=required:aws_region=foo'

# --- 呼び出し側の 2 行の書き方が失敗を取りこぼさないこと -----------------------
# eval "$(ruby ...)" と 1 行で書くと、読み取りが失敗しても終了コードが
# eval のものに化けて set -e をすり抜ける。変数へ受ける形はその場で止まる。
# if の条件部では set -e が無効になる（サブシェルにも継承される）ため、別プロセスで確かめる。
reached=$(bash -c 'set -euo pipefail
  config_vars=$(ruby scripts/lib/deployment_config.rb vars "$1" svc a=required:aws_region)
  eval "$config_vars"
  echo reached' _ "$tmp/absent.yml" 2>/dev/null)
if [[ "$reached" == reached ]]; then
  echo 'FAIL  読み取り失敗をすり抜けた'; failed=$((failed + 1))
else
  echo 'ok    変数へ受ける形は読み取り失敗で停止する'
fi

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
