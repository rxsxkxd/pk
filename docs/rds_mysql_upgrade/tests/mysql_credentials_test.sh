#!/usr/bin/env bash
# MySQL 接続情報の検証（deployment_config.rb mysql-verification）と、
# 解決から収集までの流れ（collect_green_runtime_values.rb）のテスト。
# AWS へも DB へも接続しない（aws と収集バイナリを偽物に差し替える）。
#
# 確かめること:
#   - 設定の検証（方式の値、plaintext の production 拒否、必須項目）
#   - 方式ごとに正しいユーザー名・パスワードが収集バイナリへ渡る
#   - **パスワードはコマンド引数・標準出力に出ず、環境変数だけで渡る**
#   - 無効なら何もしない。端末が無いのに対話入力が要るなら止まる
set -uo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failed=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %-50s %s\n' "$1" "$2"; failed=$((failed + 1)); }

# 指定した mysql_verification を持つ設定ファイルを作る。
make_config() {
  local env=$1 body=$2
  cat > "$tmp/c.yml" <<YAML
environment: ${env}
aws_region: ap-northeast-1
services:
  svc:
    source_db_instance_identifier: x
    target_parameter_group_template_path: examples/cfn-shorthand/mysql84-parameter-group-shorthand.yaml
    mysql_verification:
${body}
YAML
}

# --- 1. 設定の検証（deployment_config.rb）---------------------------------
expect_ng() {  # $1=説明 $2=メッセージに含むべき文字列
  if ruby scripts/lib/deployment_config.rb mysql-verification "$tmp/c.yml" svc >/dev/null 2>"$tmp/err"; then
    fail "$1" '通ってしまった'; return
  fi
  local out; out=$(cat "$tmp/err")
  [[ "$out" == *"$2"* ]] && ok "$1 → ${out%%$'\n'*}" || fail "$1" "メッセージ不一致: $out"
}

make_config production "      enabled: true
      user: verifier
      auth_method: plaintext
      password: leaked"
expect_ng 'plaintext は production で拒否' 'production では使用できません'

make_config staging "      enabled: true
      auth_method: parameter_store
      user_parameter_name: /rds-bg/staging/mysql-user"
expect_ng 'parameter_name 欠落' 'parameter_name が必要です'

make_config staging "      enabled: true
      auth_method: parameter_store
      parameter_name: /rds-bg/staging/mysql-password"
expect_ng 'user_parameter_name 欠落' 'user_parameter_name が必要です'

make_config staging "      enabled: true
      auth_method: prompt"
expect_ng 'prompt で user 欠落は拒否' 'user が必要です'

make_config staging "      enabled: true
      user: verifier
      auth_method: iam"
expect_ng 'iam は未対応の方式として拒否' 'auth_method が不正です'

# --- 2. 解決から収集まで（collect_green_runtime_values.rb）-----------------
# 偽の収集バイナリ: 受け取った引数とパスワード（環境変数）を記録し、出力ファイルを作る。
cat > "$tmp/collector" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > '$tmp/collector.args'
printf '%s' "\$MYSQL_VERIFY_PASSWORD" > '$tmp/collector.password'
while [ \$# -gt 0 ]; do [ "\$1" = --output ] && echo '{"Parameters":{}}' > "\$2"; shift; done
EOF
chmod +x "$tmp/collector"
# 偽の aws: SSM のパラメータ名に応じて値を返す。呼び出しを記録する。
mkdir -p "$tmp/bin"
cat > "$tmp/bin/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$tmp/aws.log'
[ -f '$tmp/ssm-fail' ] && { echo 'An error occurred (AccessDenied)' >&2; exit 254; }
case "\$*" in
  *"--name /p/password "*) echo 'ssm-s3cret' ;;
  *"--name /p/user "*) echo 'ssm-user' ;;
  *) echo "unexpected: \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/bin/aws"

collect() {  # 残り=追加引数。標準入力は端末でない（CI 相当）
  rm -f "$tmp"/collector.* "$tmp/out.json" "$tmp/aws.log"
  PATH="$tmp/bin:$PATH" GREEN_RUNTIME_COLLECTOR="$tmp/collector" \
    ruby scripts/collect_green_runtime_values.rb --config "$tmp/c.yml" --service svc \
    --host green.example --output "$tmp/out.json" "$@" </dev/null >"$tmp/stdout" 2>"$tmp/stderr"
}
# 収集バイナリへ渡った値を確かめる。$1=説明 $2=終了コード $3=期待ユーザー（空なら「呼ばれない」）$4=期待パスワード
expect_collect() {
  local desc=$1 status=$2 want_user=$3 want_password=${4:-}
  if [[ -z "$want_user" ]]; then
    if [[ -e "$tmp/collector.args" ]]; then fail "$desc" '収集バイナリが呼ばれた'
    else ok "${desc}（exit=${status}）"; fi
    return
  fi
  [[ $status -eq 0 ]] || { fail "$desc" "終了コード ${status}: $(cat "$tmp/stderr")"; return; }
  local args; args=$(cat "$tmp/collector.args")
  if [[ "$args" != *"--user $want_user "* ]]; then fail "$desc" "ユーザーが違う: $args"
  elif [[ "$(cat "$tmp/collector.password")" != "$want_password" ]]; then fail "$desc" 'パスワードが環境変数で渡っていない'
  elif [[ "$args" == *"$want_password"* ]] || grep -q "$want_password" "$tmp/stdout" "$tmp/stderr"; then
    fail "$desc" 'パスワードが引数か出力に漏れた'
  elif [[ ! -f "$tmp/out.json" ]]; then fail "$desc" '出力ファイルが無い'
  else ok "$desc"
  fi
}

make_config staging "      enabled: false"
collect; st=$?
expect_collect '無効なら何もしない' $st ''
[[ $st -eq 0 && ! -e "$tmp/out.json" ]] && grep -q 'mysql_verification.enabled=false' "$tmp/stdout" \
  && ok '無効: 成功で終わり、有効・無効をログへ出す' || fail '無効: 終わり方' "exit=$st"

make_config staging "      enabled: true
      auth_method: parameter_store
      parameter_name: /p/password
      user_parameter_name: /p/user"
collect; expect_collect 'parameter_store: ユーザー名もパスワードも SSM から取る' $? ssm-user ssm-s3cret
[[ $(grep -c -- '--with-decryption' "$tmp/aws.log") -eq 2 ]] && ok 'parameter_store: 2 本とも復号付きで読む' \
  || fail 'parameter_store: 復号付きで読む' "$(cat "$tmp/aws.log")"
grep -q 'auth_method=parameter_store' "$tmp/stdout" && ! grep -q '/p/' "$tmp/stdout" \
  && ok 'parameter_store: ログは方式だけで、パラメータ名を出さない' || fail 'ログの内容' "$(cat "$tmp/stdout")"

touch "$tmp/ssm-fail"
collect; st=$?
[[ $st -eq 1 ]] && grep -q AccessDenied "$tmp/stderr" && ok 'parameter_store: SSM の失敗で止める' \
  || fail 'parameter_store: SSM の失敗' "exit=$st $(cat "$tmp/stderr")"
rm -f "$tmp/ssm-fail"

make_config staging "      enabled: true
      user: verifier
      auth_method: plaintext
      password: pt-s3cret"
collect; expect_collect 'plaintext（staging）: 設定の値を使う' $? verifier pt-s3cret
grep -q 'テスト環境専用' "$tmp/stderr" && ok 'plaintext: 警告を出す' || fail 'plaintext: 警告' "$(cat "$tmp/stderr")"

make_config staging "      enabled: true
      user: verifier
      auth_method: prompt"
collect; st=$?
[[ $st -eq 1 ]] && grep -q '対話入力できない' "$tmp/stderr" && [[ ! -e "$tmp/collector.args" ]] \
  && ok 'prompt: 端末が無ければ止める（CI で待ち続けない）' || fail 'prompt: 端末なし' "exit=$st $(cat "$tmp/stderr")"

# 関数呼び出しに付けた VAR=値 は子プロセスへ渡らないので export する。
export MY_PW=override-s3cret
collect --mysql-user override --mysql-password-env MY_PW
expect_collect '--mysql-user: 設定より優先し、環境変数のパスワードを使う' $? override override-s3cret

make_config staging "      enabled: false"
collect --mysql-user override --mysql-password-env MY_PW
expect_collect '--mysql-user: 無効の設定でも収集する' $? override override-s3cret
unset MY_PW

make_config staging "      enabled: true
      auth_method: parameter_store
      parameter_name: /p/password
      user_parameter_name: /p/user
      ssl_ca: /certs/custom.pem
      port: 3307"
collect
grep -q -- '--port 3307' "$tmp/collector.args" && grep -q -- '--ssl-ca /certs/custom.pem' "$tmp/collector.args" \
  && ok 'port と ssl_ca を収集バイナリへ渡す' || fail 'port / ssl_ca' "$(cat "$tmp/collector.args")"

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
