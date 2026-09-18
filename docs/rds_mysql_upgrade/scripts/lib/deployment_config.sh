#!/usr/bin/env bash
# 実行設定 YAML（config/blue-green/<環境>.deployment.yml）の読み取り。
#
# Ruby は YAML を JSON へ変換するためだけに使う（jq は YAML を読めない）。
# YAML と JSON はどちらも Ruby の標準ライブラリ（psych / json）なので、
# 追加パッケージの導入は要らない。
# 取り出しと検証は jq が行い、各スクリプトは必要な項目だけを宣言する。
#
# 使い方:
#   source "$(dirname "$0")/lib/deployment_config.sh"
#   deployment_config_eval "$config" "$service" '
#     service($service) as $svc | {
#       config_region: required("aws_region"; .aws_region),
#       source_id:     required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
#     } | shellvars'
#
# **eval "$(deployment_config_vars ...)" と書かない。**その形だと読み取りが
# 失敗しても終了コードが eval のものに化け、set -e をすり抜けて
# 「変数が空のまま先へ進む」ことになる。deployment_config_eval は
# いったん変数へ受けてから eval するので、失敗はその場で止まる。
#
# フィルタ内では下の共通関数（required / optional / service / shellvars）と、
# 引数 ${service}（サービス名）が使える。

# 各スクリプトのフィルタへ前置する共通関数。
# 利用者が 1 箇所しかないため、別ファイル（.jq）へは分けずここに置く。
# jq のモジュール機構を使わないので、ライブラリパスの解決も要らない。
DEPLOYMENT_CONFIG_FUNCTIONS='
  # 必須項目。空・未定義なら文脈付きで落とす。
  # jq の error は終了コード 5 を返すため、set -e 配下でそのまま停止する。
  def required($path; $value):
    if ($value // "") == "" then error("\($path) が未定義である") else $value end;

  # 任意項目。未定義なら既定値を使う。
  def optional($value; $fallback):
    if ($value // "") == "" then $fallback else $value end;

  # 対象サービスの定義を取り出す。
  def service($name):
    .services[$name] // error("services.\($name) が未定義である");

  # オブジェクトを `key='"'"'value'"'"'` の代入行へ変換する。
  # @sh がシェル用のクォートを行う（Python の shlex.quote と同じ役割）。
  def shellvars:
    to_entries[] | "\(.key)=\(.value | tostring | @sh)";
'

# YAML を JSON にするためだけの変換。設定の読み取りでこれ以外のコードを書かない。
# safe_load はエイリアス・任意クラスの復元を許さない（設定ファイルは素のマッピングだけ）。
deployment_config_json() {
  ruby -ryaml -rjson -e 'print JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$1"
}

# 設定から eval 可能な代入行を組み立てる。
# 使い方: deployment_config_vars <config> <service> <jq フィルタ>
deployment_config_vars() {
  local config=$1 service=$2 filter=$3
  # Ruby の失敗を握り潰さないよう、パイプではなくいったん変数へ受ける。
  # バックトレースをそのまま出すと読みにくいため、最初の 1 行だけを添える。
  local document reason
  reason=$(mktemp "${TMPDIR:-/tmp}/deployment-config.XXXXXX")
  document=$(deployment_config_json "$config" 2>"$reason") || {
    echo "${config}: YAML を読み込めなかった: $(head -n 1 "$reason")" >&2
    rm -f "$reason"
    return 1
  }
  rm -f "$reason"
  printf '%s' "$document" \
    | jq -r --arg service "$service" "${DEPLOYMENT_CONFIG_FUNCTIONS} ${filter}"
}

# deployment_config_vars の結果を呼び出し元のスコープへ展開する。
# **読み取りに失敗したらここで止める。**（上の注意書きを参照）
# 関数内で local を付けずに eval するため、作られる変数は呼び出し元から見える。
deployment_config_eval() {
  local deployment_config_assignments
  deployment_config_assignments=$(deployment_config_vars "$@") || return 1
  eval "$deployment_config_assignments"
}
