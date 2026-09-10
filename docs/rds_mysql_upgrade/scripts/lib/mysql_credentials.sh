#!/usr/bin/env bash
# MySQL 接続情報の解決。
# Step 4（verify_green.sh の実効値収集）と Step 7（cleanup.sh の逆レプリケーション確認）で共用する。
#
# 設定ファイルの mysql_verification ブロックから接続方式を読み、方式ごとに
# パスワード（または IAM 認証トークン）を解決する。呼び出し側は方式を意識しない。
#
# 対応する auth_method:
#   secrets_manager  Secrets Manager のシークレット（JSON の password を読む）
#   parameter_store  SSM Parameter Store の SecureString
#   plaintext        設定ファイルに直書き。テスト環境専用（production では拒否する）
#   prompt           対話入力。ローカル実行専用（CI では成立しない）
#
# IAM データベース認証（auth_method: iam）は未実装である。設定すると明示的に失敗する。
#
# 設計上の約束:
#   - 解決した値は変数に置くだけで、標準出力・コマンド引数・成果物へは出さない。
#   - 呼び出し側は MYSQL_PWD 経由で MySQL クライアントのプロセスにだけ渡す。
#   - 読み取りは config と AWS の読み取り API のみ。AWS の状態を変更しない。

# 設定ファイルから mysql_verification を読む。AWS API は呼び出さない。
#
# 使い方: read_mysql_verification_config <config> <service>
# 設定する変数:
#   MYSQL_VERIFY_ENABLED         true / false
#   MYSQL_VERIFY_USER            接続ユーザー
#   MYSQL_VERIFY_AUTH            上記 auth_method のいずれか
#   MYSQL_VERIFY_SECRET_ID       secrets_manager のとき
#   MYSQL_VERIFY_PARAMETER_NAME  parameter_store のとき
#   MYSQL_VERIFY_PLAINTEXT       plaintext のとき
#   MYSQL_VERIFY_SSL_CA          TLS 用の CA バンドルのパス（空なら未指定）
#   MYSQL_VERIFY_PORT            接続ポート（既定 3306）
read_mysql_verification_config() {
  local config=$1 service=$2 resolved
  # eval "$(...)" は python の終了コードを握り潰すため、いったん変数へ受けて判定する。
  resolved=$(python3 -c '
import shlex, sys, yaml

d = yaml.safe_load(open(sys.argv[1]))
services = d.get("services") or {}
if sys.argv[2] not in services:
    sys.exit(sys.argv[1] + ": services." + sys.argv[2] + " が未定義です")
m = services[sys.argv[2]].get("mysql_verification") or {}
environment = str(d.get("environment") or "")

VALID = ("secrets_manager", "parameter_store", "plaintext", "prompt")
UNIMPLEMENTED = ("iam",)
enabled = bool(m.get("enabled", False))
auth = str(m.get("auth_method") or "prompt")

if enabled:
    if auth in UNIMPLEMENTED:
        sys.exit("auth_method: " + auth + " は未実装です（後日対応）。"
                 "現在は " + " / ".join(VALID) + " が使えます")
    if auth not in VALID:
        sys.exit("mysql_verification.auth_method が不正です: " + auth
                 + "（有効な値: " + ", ".join(VALID) + "）")
    # ユーザー名は方式によっては秘匿側（シークレット / パラメータ）から取得できる。
    # その場合 config の user は不要である。取得できない方式では必須とする。
    supplies_user = (auth == "secrets_manager"
                     or (auth == "parameter_store" and m.get("user_parameter_name")))
    if not m.get("user") and not supplies_user:
        sys.exit("mysql_verification.user が必要です"
                 "（parameter_store でユーザー名も秘匿する場合は user_parameter_name を指定してください）")
    # plaintext は設定ファイルが Git 追跡対象であるため、本番では使わせない。
    if auth == "plaintext" and environment == "production":
        sys.exit("auth_method: plaintext は production では使用できません。"
                 "secrets_manager / parameter_store のいずれかを使ってください")
    required = {"secrets_manager": "secret_id",
                "parameter_store": "parameter_name",
                "plaintext": "password"}
    key = required.get(auth)
    if key and not m.get(key):
        sys.exit("auth_method: " + auth + " には mysql_verification." + key + " が必要です")

values = {
    "MYSQL_VERIFY_ENABLED": "true" if enabled else "false",
    "MYSQL_VERIFY_USER": m.get("user") or "",
    "MYSQL_VERIFY_AUTH": auth,
    "MYSQL_VERIFY_SECRET_ID": m.get("secret_id") or "",
    "MYSQL_VERIFY_PARAMETER_NAME": m.get("parameter_name") or "",
    "MYSQL_VERIFY_USER_PARAMETER_NAME": m.get("user_parameter_name") or "",
    "MYSQL_VERIFY_PLAINTEXT": m.get("password") or "",
    "MYSQL_VERIFY_SSL_CA": m.get("ssl_ca") or "",
    "MYSQL_VERIFY_PORT": str(m.get("port") or 3306),
}
for k, v in values.items():
    print(k + "=" + shlex.quote(str(v)))
' "$config" "$service") || return 1
  eval "$resolved"
}

# 方式に応じてユーザー名とパスワードを解決する。
#
# 使い方: resolve_mysql_credentials <region> <profile>
# 設定する変数:
#   MYSQL_VERIFY_USER      解決したユーザー名。秘匿側が持つ場合はその値で上書きする
#   MYSQL_VERIFY_PASSWORD  解決したパスワード。prompt のときは空（対話入力に委ねる）
#
# ユーザー名も秘匿対象として扱える。
#   secrets_manager  シークレット JSON の username を使う（無ければ config の user）
#   parameter_store  user_parameter_name を指定すればそこから取る（無ければ config の user）
#
# 解決した値は決して echo しない。
resolve_mysql_credentials() {
  local region=$1 profile=$2
  local aws_args=(--region "$region")
  [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

  case "$MYSQL_VERIFY_AUTH" in
    secrets_manager)
      local secret_json secret_user
      secret_json=$(aws "${aws_args[@]}" secretsmanager get-secret-value \
        --secret-id "$MYSQL_VERIFY_SECRET_ID" --query SecretString --output text)
      MYSQL_VERIFY_PASSWORD=$(printf '%s' "$secret_json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
      # username はシークレットにあれば使う。無ければ config の user を残す。
      secret_user=$(printf '%s' "$secret_json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("username") or "")')
      [[ -n "$secret_user" ]] && MYSQL_VERIFY_USER="$secret_user"
      unset secret_json secret_user
      ;;
    parameter_store)
      MYSQL_VERIFY_PASSWORD=$(aws "${aws_args[@]}" ssm get-parameter \
        --name "$MYSQL_VERIFY_PARAMETER_NAME" --with-decryption \
        --query 'Parameter.Value' --output text)
      if [[ -n "$MYSQL_VERIFY_USER_PARAMETER_NAME" ]]; then
        MYSQL_VERIFY_USER=$(aws "${aws_args[@]}" ssm get-parameter \
          --name "$MYSQL_VERIFY_USER_PARAMETER_NAME" --with-decryption \
          --query 'Parameter.Value' --output text)
      fi
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

  # 秘匿側から取得する構成では、ここで初めてユーザー名が確定する。
  if [[ -z "$MYSQL_VERIFY_USER" ]]; then
    echo "MySQL の接続ユーザー名を解決できなかった（auth_method: ${MYSQL_VERIFY_AUTH}）。" >&2
    echo "config の mysql_verification.user か、シークレット側のユーザー名を確認する。" >&2
    return 1
  fi
}
