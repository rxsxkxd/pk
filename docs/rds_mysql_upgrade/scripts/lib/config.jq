# 実行設定（config/blue-green/<環境>.deployment.yml を JSON 化したもの）から
# シェル変数を組み立てるための共通関数。
#
# 使い方は scripts/lib/deployment_config.sh を参照する。
# 各スクリプトは「どのキーを、どの名前のシェル変数へ、必須か任意か」だけを書く。

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

# オブジェクトを `key='value'` の代入行へ変換する。
# @sh がシェル用のクォートを行う（Python の shlex.quote と同じ役割）。
def shellvars:
  to_entries[] | "\(.key)=\(.value | tostring | @sh)";
