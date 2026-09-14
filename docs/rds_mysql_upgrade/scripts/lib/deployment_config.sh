#!/usr/bin/env bash
# 実行設定 YAML の読み取り。
#
# python3 は YAML を JSON へ変換するためだけに使う（jq は YAML を読めない）。
# 取り出しと検証は jq が行い、各スクリプトは必要な項目だけを宣言する。
# 共通の jq 関数は同じディレクトリの config.jq にある。
#
# 使い方:
#   source "$(dirname "$0")/lib/deployment_config.sh"
#   eval "$(deployment_config_vars "$config" "$service" '
#     service($service) as $svc | {
#       config_region: required("aws_region"; .aws_region),
#       source_id:     required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
#     } | shellvars')"
#
# フィルタ内では config.jq の関数（required / optional / service / shellvars）と、
# 引数 ${service}（サービス名）が使える。

# jq のライブラリ位置は source 時に確定させる。関数の中では BASH_SOURCE が
# 呼び出し元を指すことがあるため、トップレベルで解決しておく。
DEPLOYMENT_CONFIG_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# YAML を JSON にするためだけの変換。ここ以外で python3 を使わない。
deployment_config_json() {
  python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"
}

# 設定から eval 可能な代入行を組み立てる。
# 使い方: deployment_config_vars <config> <service> <jq フィルタ>
deployment_config_vars() {
  local config=$1 service=$2 filter=$3
  # python3 の失敗を握り潰さないよう、パイプではなくいったん変数へ受ける。
  # トレースバックをそのまま出すと読みにくいため、最後の 1 行だけを添える。
  local document reason
  reason=$(mktemp "${TMPDIR:-/tmp}/deployment-config.XXXXXX")
  document=$(deployment_config_json "$config" 2>"$reason") || {
    echo "${config}: YAML を読み込めなかった: $(tail -n 1 "$reason")" >&2
    rm -f "$reason"
    return 1
  }
  rm -f "$reason"
  printf '%s' "$document" \
    | jq -L "$DEPLOYMENT_CONFIG_LIB_DIR" -r --arg service "$service" "include \"config\"; $filter"
}
