#!/usr/bin/env bash
# MySQL 接続情報の解決。
# Step 4（verify_green.sh の実効値収集）で使う。
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

# 設定ファイルの mysql_verification の読み取りと検証は deployment_config.rb が行う。
# 呼び出し側は次の 2 行で MYSQL_VERIFY_* を作ってから resolve_mysql_credentials を呼ぶ。
#
#   mysql_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" mysql-verification "$config" "$service")
#   eval "$mysql_vars"
#
# 作られる変数:
#   MYSQL_VERIFY_ENABLED              true / false
#   MYSQL_VERIFY_USER                 接続ユーザー（plaintext / prompt のとき）
#   MYSQL_VERIFY_AUTH                 上記 auth_method のいずれか
#   MYSQL_VERIFY_PARAMETER_NAME       parameter_store のとき（パスワード）
#   MYSQL_VERIFY_USER_PARAMETER_NAME  parameter_store のとき（ユーザー名）
#   MYSQL_VERIFY_PLAINTEXT            plaintext のとき
#   MYSQL_VERIFY_SSL_CA               TLS 用の CA バンドルのパス（空なら未指定）
#   MYSQL_VERIFY_PORT                 接続ポート（既定 3306）

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
