#!/usr/bin/env bash
# ドライバ検証の一括実行。収集（3 言語）→ 判定・レポート生成（Ruby）をまとめて行う。
#
# 前提: docker compose up -d と ./setup.sh が完了していること。
#
# 収集と判定を分離しているため、本スクリプトは次の 2 段で構成される。
#   1. 各言語の probe が DB へ接続し、観測した事実を reports/<言語>.json へ書き出す
#   2. generate_report.rb が JSON を読み、判定して Markdown を生成する（DB へ接続しない）
#
# すべての判定が通れば終了コード 0、通らなければ 1 を返す。
set -euo pipefail
cd "$(dirname "$0")"

ALL_LANGUAGES=(go ruby python)

usage() {
  cat <<'USAGE'
Usage: verify.sh [options]
  --languages LIST   収集する言語をカンマ区切りで指定（default: go,ruby,python）
  --skip-collect     収集を行わず、既存の JSON からレポートだけを生成する
  --keep-going       収集が失敗した言語があっても、残りを続行する
  --clean            実行前に reports/ の生成物をすべて削除する
  -h, --help         このヘルプを表示する

例:
  ./verify.sh                        # 3 言語を収集してレポートを生成する
  ./verify.sh --languages go,ruby    # Go と Ruby だけ収集する
  ./verify.sh --skip-collect         # 収集済み JSON からレポートを作り直す
USAGE
}

languages=("${ALL_LANGUAGES[@]}")
skip_collect=false
keep_going=false
clean=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --languages) IFS=',' read -r -a languages <<< "${2:?}"; shift 2 ;;
    --skip-collect) skip_collect=true; shift ;;
    --keep-going) keep_going=true; shift ;;
    --clean) clean=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for language in "${languages[@]}"; do
  # 変数展開の直後に全角文字が続く場合は、波括弧で変数名の終わりを明示する。
  [[ " ${ALL_LANGUAGES[*]} " == *" ${language} "* ]] ||
    { echo "Unknown language: ${language}（指定できるのは ${ALL_LANGUAGES[*]}）" >&2; exit 2; }
done

[[ -f .env ]] || { echo '.env がない。cp .env.example .env を先に実行する。' >&2; exit 2; }

if [[ "$clean" == true ]]; then
  echo '==> reports/ を空にする'
  rm -f probe/reports/*.json probe/reports/*.md
fi

# --skip-collect のときも参照するため、先に宣言しておく。
failed_collect=()

if [[ "$skip_collect" == false ]]; then
  # 検証データが投入済みかを確認する。未投入のまま収集すると
  # 各言語が個別に SQL エラーになり、原因が分かりにくくなるため先に見る。
  echo '==> 前提確認: 検証データが投入されているか'
  # shellcheck disable=SC1091
  source .env
  rows=$(docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" source \
    mysql -uroot --batch --skip-column-names tzcheck -e 'SELECT COUNT(*) FROM t' 2>/dev/null || echo '')
  if [[ "$rows" != 2 ]]; then
    echo "    検証データが見つからない（source の tzcheck.t）。" >&2
    echo "    先に ./setup.sh を実行する。" >&2
    exit 1
  fi
  echo "    source の tzcheck.t = $rows 件"

  for language in "${languages[@]}"; do
    echo "==> 収集: ${language}"
    # 失敗時に古い JSON が残ると誤ったレポートになるため、収集前に消す。
    rm -f "probe/reports/${language}.json"
    if docker compose run --rm "probe-${language}"; then
      :
    else
      failed_collect+=("$language")
      echo "    収集に失敗した: $language" >&2
      [[ "$keep_going" == true ]] || { echo '--keep-going を付けると残りを続行できる。' >&2; exit 1; }
    fi
  done

  if [[ ${#failed_collect[@]} -gt 0 ]]; then
    echo "収集に失敗した言語: ${failed_collect[*]}" >&2
  fi
fi

# レポート生成は reports/ にある JSON をすべて対象にする。今回収集していない言語の
# JSON が残っている場合、過去の実行結果が混ざるため明示的に知らせる。
if [[ "$skip_collect" == false ]]; then
  for language in "${ALL_LANGUAGES[@]}"; do
    [[ " ${languages[*]} " == *" ${language} "* ]] && continue
    [[ -f "probe/reports/${language}.json" ]] || continue
    collected_at=$(grep -o '"collected_at": *"[^"]*"' "probe/reports/${language}.json" |
      head -1 | sed 's/.*: *"//; s/"$//')
    echo "==> 注意: ${language} は今回収集していないが、過去の JSON が残っている" >&2
    echo "    収集時刻 ${collected_at} の結果がレポートに含まれる。" >&2
    echo "    除外するには --clean を付けて実行し直す。" >&2
  done
fi

echo '==> 判定とレポート生成'
if docker compose run --rm probe-report; then
  report_status=0
else
  report_status=$?
fi

echo
echo "生成物: $(pwd)/probe/reports/"
ls -1 probe/reports/ 2>/dev/null | sed 's/^/  /' || true

if [[ "$report_status" -eq 0 && "${#failed_collect[@]}" -eq 0 ]]; then
  echo
  echo '検証は成功した。'
  exit 0
fi

echo
echo '検証は失敗した。上記のレポートで FAIL 項目を確認する。' >&2
exit 1
