#!/usr/bin/env bash
# mysql_credentials.sh の設定読み取りと検証ロジックのテスト。AWS へは接続しない。
# 実行: scripts/lib/mysql_credentials_test.sh
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=mysql_credentials.sh
source ./mysql_credentials.sh

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failed=0

# 指定した mysql_verification を持つ設定ファイルを作る。
make_config() {
  local env=$1 body=$2
  cat > "$tmp/c.yml" <<YAML
environment: ${env}
aws_region: ap-northeast-1
services:
  svc:
    source_db_instance_identifier: x
    mysql_verification:
${body}
YAML
}

# 成功を期待する。第 3 引数以降は "変数名=期待値"。
expect_ok() {
  local desc=$1; shift
  # サブシェルにすると関数が設定した変数が失われるため、直接呼ぶ。
  if ! read_mysql_verification_config "$tmp/c.yml" svc 2>"$tmp/err"; then
    printf 'FAIL  %-46s 失敗した: %s\n' "$desc" "$(cat "$tmp/err")"; failed=$((failed+1)); return
  fi
  local bad=''
  for pair in "$@"; do
    local k=${pair%%=*} v=${pair#*=}
    [[ "${!k:-}" == "$v" ]] || bad="$bad ${k}=${!k:-}(期待 $v)"
  done
  if [[ -z "$bad" ]]; then printf 'ok    %s\n' "$desc"
  else printf 'FAIL  %-46s%s\n' "$desc" "$bad"; failed=$((failed+1)); fi
}

# 失敗を期待する。第 2 引数はエラーメッセージに含まれるべき文字列。
expect_ng() {
  local desc=$1 want=$2
  if read_mysql_verification_config "$tmp/c.yml" svc 2>"$tmp/err"; then
    printf 'FAIL  %-46s 通ってしまった\n' "$desc"; failed=$((failed+1)); return
  fi
  out=$(cat "$tmp/err")
  if [[ "$out" == *"$want"* ]]; then printf 'ok    %-46s → %s\n' "$desc" "${out%%$'\n'*}"
  else printf 'FAIL  %-46s メッセージ不一致: %s\n' "$desc" "$out"; failed=$((failed+1)); fi
}

make_config staging "      enabled: false"
expect_ok '無効時は user 未指定でも通る' MYSQL_VERIFY_ENABLED=false

make_config staging "      enabled: true
      user: verifier
      auth_method: prompt"
expect_ok 'D: prompt' MYSQL_VERIFY_ENABLED=true MYSQL_VERIFY_AUTH=prompt MYSQL_VERIFY_PORT=3306

make_config staging "      enabled: true
      user: verifier
      auth_method: secrets_manager
      secret_id: rds-bg/staging/mysql"
expect_ok 'A: secrets_manager' MYSQL_VERIFY_AUTH=secrets_manager MYSQL_VERIFY_SECRET_ID=rds-bg/staging/mysql

make_config staging "      enabled: true
      user: verifier
      auth_method: parameter_store
      parameter_name: /rds-bg/staging/mysql"
expect_ok 'B: parameter_store' MYSQL_VERIFY_AUTH=parameter_store MYSQL_VERIFY_PARAMETER_NAME=/rds-bg/staging/mysql

make_config staging "      enabled: true
      user: verifier
      auth_method: plaintext
      password: test-only"
expect_ok 'C: plaintext（staging では許可）' MYSQL_VERIFY_AUTH=plaintext MYSQL_VERIFY_PLAINTEXT=test-only

# --- 異常系 ---
make_config production "      enabled: true
      user: verifier
      auth_method: plaintext
      password: leaked"
expect_ng 'C: plaintext は production で拒否' 'production では使用できません'

make_config staging "      enabled: true
      user: verifier
      auth_method: secrets_manager"
expect_ng 'secret_id 欠落' 'secret_id が必要です'

make_config staging "      enabled: true
      user: verifier
      auth_method: parameter_store"
expect_ng 'parameter_name 欠落' 'parameter_name が必要です'

make_config staging "      enabled: true
      auth_method: prompt"
expect_ng 'user 欠落' 'user が必要です'

make_config staging "      enabled: true
      user: verifier
      auth_method: iam"
expect_ng 'E: iam は未実装として明示的に失敗' '未実装です'

make_config staging "      enabled: true
      user: verifier
      auth_method: kerberos"
expect_ng '未知の方式' 'auth_method が不正です'

# --- 解決ロジック（AWS 不要な方式のみ）---
make_config staging "      enabled: true
      user: verifier
      auth_method: plaintext
      password: s3cret"
read_mysql_verification_config "$tmp/c.yml" svc
resolve_mysql_password ap-northeast-1 '' 2>/dev/null
[[ "$MYSQL_VERIFY_PASSWORD" == 's3cret' ]] \
  && echo 'ok    C: plaintext のパスワード解決' \
  || { echo 'FAIL  C: plaintext のパスワード解決'; failed=$((failed+1)); }

make_config staging "      enabled: true
      user: verifier
      auth_method: prompt"
read_mysql_verification_config "$tmp/c.yml" svc
resolve_mysql_password ap-northeast-1 ''
[[ -z "$MYSQL_VERIFY_PASSWORD" ]] \
  && echo 'ok    D: prompt は空（対話入力へ委ねる）' \
  || { echo 'FAIL  D: prompt が空でない'; failed=$((failed+1)); }

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
