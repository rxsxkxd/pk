#!/usr/bin/env bash
# Step 4 補助: Green DB の実効値を収集する。AWS API は呼び出さない。
#
# 収集そのものは Go のバイナリ（scripts/collect_green_runtime_values/）が行う。
# **MySQL クライアントは使わない。**VerifyGreen は RDS のある VPC 内で動かす場合があり、
# そこから apt リポジトリへ到達できないため実行時に導入できない。加えて
# aws/codebuild/standard:7.0 は mysql クライアントを含まない。
#
# このスクリプトの役目は次の 2 つだけである。
#   - バイナリの場所を決める（CI は事前ビルド済みを受け取り、ここではビルドしない）
#   - パスワードを環境変数で渡す。空なら対話入力を促す
#
# 収集対象のパラメータ名は、バイナリが CloudFormation テンプレートから直接読む
# （短縮記法 !Ref / !Sub の正規化を含む。scripts/internal/cfn）。
set -euo pipefail

usage() {
  echo 'Usage: collect_green_runtime_values.sh --template FILE --host HOST --user USER --output FILE' \
       '[--collector FILE] [--port PORT] [--password-env NAME] [--ssl-ca FILE]'
}
template=''; host=''; port=''; user=''; output=''; password_env='MYSQL_PASSWORD'; ssl_ca=''
# 収集に使うビルド済みバイナリ。未指定ならその場でビルドする（ローカル実行用）。
collector=${GREEN_RUNTIME_COLLECTOR:-}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) template=${2:?}; shift 2 ;;
    --collector) collector=${2:?}; shift 2 ;;
    --host) host=${2:?}; shift 2 ;;
    --port) port=${2:?}; shift 2 ;;
    --user) user=${2:?}; shift 2 ;;
    --output) output=${2:?}; shift 2 ;;
    --password-env) password_env=${2:?}; shift 2 ;;
    --ssl-ca) ssl_ca=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$template" && -n "$host" && -n "$user" && -n "$output" ]] || { usage >&2; exit 2; }

# **CI ではビルド済みバイナリを受け取る。**VerifyGreen は Go も外部ネットワークも
# 持たない前提なので、ここでビルドしない。未指定のローカル実行でだけその場でビルドする。
if [[ -z "$collector" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    echo '実効値の収集バイナリが指定されておらず、Go も見つからない。' >&2
    echo 'GREEN_RUNTIME_COLLECTOR か --collector でビルド済みバイナリを渡すこと。' >&2
    exit 1
  fi
  repository_root=$(cd "$(dirname "$0")/.." && pwd)
  collector=$(mktemp "${TMPDIR:-/tmp}/green-runtime-collector.XXXXXX")
  trap 'rm -f "$collector"' EXIT
  go -C "$repository_root" build -o "$collector" ./scripts/collect_green_runtime_values
fi

collect_args=(--template "$template" --host "$host" --user "$user" --output "$output"
              --password-env "$password_env")
[[ -n "$port" ]] && collect_args+=(--port "$port")
# 未指定ならバイナリへ焼き込んだ RDS のトラストストアを使う。
[[ -n "$ssl_ca" ]] && collect_args+=(--ssl-ca "$ssl_ca")

# パスワードは環境変数だけで渡す。コマンド引数・成果物には出力しない。
# 空の場合（auth_method: prompt）はここで対話入力を促す。エコーしない。
if [[ -z "${!password_env:-}" ]]; then
  read -rs -p "MySQL password for ${user}@${host}: " interactive_password
  echo
  export MYSQL_PASSWORD_INTERACTIVE="$interactive_password"
  unset interactive_password
  collect_args+=(--password-env MYSQL_PASSWORD_INTERACTIVE)
fi

# [DB 読み取り] performance_schema.global_variables から実効値を取る。変更は行わない。
"$collector" "${collect_args[@]}"
