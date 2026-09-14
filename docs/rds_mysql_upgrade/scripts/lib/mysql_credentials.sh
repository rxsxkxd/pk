#!/usr/bin/env bash
# MySQL 接続情報の解決。
# Step 4（verify_green.sh の実効値収集）と Step 7（cleanup.sh の逆レプリケーション確認）で共用する。
#
# 設定ファイルの mysql_verification ブロックから接続方式を読み、方式ごとに
# パスワード（または IAM 認証トークン）を解決する。呼び出し側は方式を意識しない。
#
# 対応する auth_method:
#   parameter_store  SSM Parameter Store の SecureString。CI で使う既定の方式。
#                    パスワードとユーザー名の 2 本を必ず指定する
#   plaintext        設定ファイルに直書き。テスト環境専用（production では拒否する）
#   prompt           対話入力。ローカル実行専用（CI では成立しない）
#
# 設計上の約束:
#   - 解決した値は変数に置くだけで、標準出力・コマンド引数・成果物へは出さない。
#   - 呼び出し側は MYSQL_PWD 経由で MySQL クライアントのプロセスにだけ渡す。
#   - 読み取りは config と AWS の読み取り API のみ。AWS の状態を変更しない。

# 設定の読み取りは deployment_config.sh（python3 で YAML→JSON、jq で取り出し）に委ねる。
# shellcheck source=deployment_config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deployment_config.sh"

# 設定ファイルから mysql_verification を読む。AWS API は呼び出さない。
#
# 使い方: read_mysql_verification_config <config> <service>
# 設定する変数:
#   MYSQL_VERIFY_ENABLED         true / false
#   MYSQL_VERIFY_USER            接続ユーザー
#   MYSQL_VERIFY_AUTH            上記 auth_method のいずれか
#   MYSQL_VERIFY_PARAMETER_NAME  parameter_store のとき
#   MYSQL_VERIFY_PLAINTEXT       plaintext のとき
#   MYSQL_VERIFY_SSL_CA          TLS 用の CA バンドルのパス（空なら未指定）
#   MYSQL_VERIFY_PORT            接続ポート（既定 3306）
read_mysql_verification_config() {
  local config=$1 service=$2 resolved
  # jq の失敗（検証エラー）を握り潰さないよう、いったん変数へ受けて判定する。
  # 検証内容は上のコメントのとおりで、jq の error() が理由を stderr へ出す。
  resolved=$(deployment_config_vars "$config" "$service" '
    service($service).mysql_verification as $m
    | (.environment // "") as $environment
    | ($m.enabled // false) as $enabled
    | ($m.auth_method // "prompt") as $auth
    | (["parameter_store", "plaintext", "prompt"]) as $valid
    | (if $enabled then
        (if ($valid | index($auth)) == null then
           error("mysql_verification.auth_method が不正です: \($auth)（有効な値: \($valid | join(", "))）")
         # parameter_store はユーザー名も必ず秘匿側へ置く。config の user は使わない。
         # 秘匿側を持たない plaintext / prompt では config の user を必須とする。
         elif $auth != "parameter_store" and (($m.user // "") == "") then
           error("auth_method: \($auth) には mysql_verification.user が必要です")
         # plaintext は設定ファイルが Git 追跡対象であるため、本番では使わせない。
         elif $auth == "plaintext" and $environment == "production" then
           error("auth_method: plaintext は production では使用できません。parameter_store を使ってください")
         else
           ({parameter_store: ["parameter_name", "user_parameter_name"], plaintext: ["password"]}[$auth] // [])
           | map(select(($m[.] // "") == "")) | first
           | if . != null then
               error("auth_method: \($auth) には mysql_verification.\(.) が必要です")
             else empty end
         end)
       else empty end)
    // {
      MYSQL_VERIFY_ENABLED:             (if $enabled then "true" else "false" end),
      MYSQL_VERIFY_USER:                optional($m.user; ""),
      MYSQL_VERIFY_AUTH:                $auth,
      MYSQL_VERIFY_PARAMETER_NAME:      optional($m.parameter_name; ""),
      MYSQL_VERIFY_USER_PARAMETER_NAME: optional($m.user_parameter_name; ""),
      MYSQL_VERIFY_PLAINTEXT:           optional($m.password; ""),
      MYSQL_VERIFY_SSL_CA:              optional($m.ssl_ca; ""),
      MYSQL_VERIFY_PORT:                optional($m.port; 3306),
    } | shellvars') || return 1
  eval "$resolved"
}

# 方式に応じてユーザー名とパスワードを解決する。
#
# 使い方: resolve_mysql_credentials <region> <profile>
# 設定する変数:
#   MYSQL_VERIFY_USER      解決したユーザー名。秘匿側が持つ場合はその値で上書きする
#   MYSQL_VERIFY_PASSWORD  解決したパスワード。prompt のときは空（対話入力に委ねる）
#
# ユーザー名も秘匿対象である。
#   parameter_store  user_parameter_name のパラメータから必ず取得する
#
# 解決した値は決して echo しない。
resolve_mysql_credentials() {
  local region=$1 profile=$2
  local aws_args=(--region "$region")
  [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

  case "$MYSQL_VERIFY_AUTH" in
    parameter_store)
      MYSQL_VERIFY_PASSWORD=$(aws "${aws_args[@]}" ssm get-parameter \
        --name "$MYSQL_VERIFY_PARAMETER_NAME" --with-decryption \
        --query 'Parameter.Value' --output text)
      MYSQL_VERIFY_USER=$(aws "${aws_args[@]}" ssm get-parameter \
        --name "$MYSQL_VERIFY_USER_PARAMETER_NAME" --with-decryption \
        --query 'Parameter.Value' --output text)
      ;;
    plaintext)
      MYSQL_VERIFY_PASSWORD="$MYSQL_VERIFY_PLAINTEXT"
      echo 'WARNING: auth_method: plaintext を使用している。設定ファイルは Git 追跡対象であるため、テスト環境専用とすること。' >&2
      ;;
    prompt)
      # 空にしておくと collect 側が mysql --password（対話入力）へ分岐する。
      MYSQL_VERIFY_PASSWORD=''
      ;;
    *)
      echo "未知の auth_method: $MYSQL_VERIFY_AUTH" >&2
      return 1
      ;;
  esac

  # parameter_store では、ここで初めてユーザー名が確定する。
  if [[ -z "$MYSQL_VERIFY_USER" ]]; then
    echo "MySQL の接続ユーザー名を解決できなかった（auth_method: ${MYSQL_VERIFY_AUTH}）。" >&2
    echo "config の mysql_verification.user か、user_parameter_name の値を確認する。" >&2
    return 1
  fi
}
