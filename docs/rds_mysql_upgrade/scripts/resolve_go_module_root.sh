#!/usr/bin/env bash
# Go のモジュールルートを突き止め、**期待する構成になっていることを検査する。**
# 見つけたモジュールルートを標準出力へ 1 行で返す。診断は標準エラーへ出す。
#
# 期待する構成:
#   <モジュールルート>/go.mod                                      module rds-mysql-upgrade
#   <モジュールルート>/go.sum                                      依存の固定
#   <モジュールルート>/scripts/generate_green_verification_report/  package main
#   <モジュールルート>/scripts/collect_green_runtime_values/        package main
#   <モジュールルート>/scripts/collect_green_state/                 package main
#   <モジュールルート>/tools/                                       人が実行するコマンド
#
# **この形から外れていたら、黙って別のものをビルドさせずに落とす。**
# Go の module モードには相対 import が無く、モジュール内の import はすべて
# go.mod の module 行を接頭辞に持つ。そのため go.mod の位置がずれると Go は
# rds-mysql-upgrade/... を外部モジュール扱いして失敗し、エラー文にモジュール名が
# 出るため原因がモジュール名に見えてしまう。実際の原因は構成のずれなので、
# ここで構成として指摘する。
#
# 使い方（ci/codebuild/build-report-tool.yml から。set -e 配下で）:
#   module_dir=$(bash scripts/resolve_go_module_root.sh)
#
# 探索の起点は CODEBUILD_SRC_DIR。無ければカレントディレクトリを使うので、
# ローカルからもそのまま実行できる。
set -eu

usage() { echo 'Usage: resolve_go_module_root.sh [--search-root DIR] [--max-depth N]'; }
search_root=${CODEBUILD_SRC_DIR:-}
max_depth=4
while [ $# -gt 0 ]; do
  case "$1" in
    --search-root) search_root=${2:?}; shift 2 ;;
    --max-depth) max_depth=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$search_root" ] || search_root=$(pwd)

# CODEBUILD_SRC_DIR はシンボリックリンクである
# （/codebuild/output/srcNNN/src -> /codebuild/output/srcDownload/src）。
# find は起点がシンボリックリンクのとき既定で辿らないため、実体のパスへ
# 解決してから探索する。これを忘れると go.mod が 1 件も見つからない。
search_root=$(cd "$search_root" && pwd -P)

# module 行で選ぶ。examples 配下の probe は別モジュール（module tzprobe）なので拾わない。
found=$(find "$search_root" -maxdepth "$max_depth" -name go.mod -type f 2>/dev/null \
        | while IFS= read -r candidate; do
            if grep -q '^module[[:space:]]\+rds-mysql-upgrade$' "$candidate"; then echo "$candidate"; fi
          done)

count=$(printf '%s\n' "$found" | grep -c . || true)
if [ "$count" -eq 0 ]; then
  echo '構成が期待と違う: module rds-mysql-upgrade の go.mod が無い。' >&2
  echo "探索した場所: ${search_root}（maxdepth ${max_depth}）" >&2
  echo '見つかった go.mod:' >&2
  # リダイレクトの順序に注意する。`2>/dev/null >&2` と書くと stderr を捨ててから
  # stdout をそこへ向けることになり、**一覧が丸ごと消える。**
  # 先に stdout を stderr へ向け、その後で find 自身のエラーだけを捨てる。
  find "$search_root" -maxdepth "$max_depth" -name go.mod -type f 1>&2 2>/dev/null || true
  echo 'go.mod と go.sum がリポジトリに入っているか確認する（git ls-files go.mod go.sum）。' >&2
  exit 1
fi
if [ "$count" -gt 1 ]; then
  echo '構成が期待と違う: module rds-mysql-upgrade の go.mod が複数ある。' >&2
  printf '%s\n' "$found" >&2
  echo 'モジュールはプロジェクト直下の 1 つだけである。重複したチェックアウトを取り除く。' >&2
  exit 1
fi

module_dir=$(cd "$(dirname "$found")" && pwd)

# 旧構成（go.mod が scripts/ 配下）を名指しで拒否する。この形だと
# scripts/ から親の internal/ が見えず、ビルド対象の指定も変わる。
if [ "$(basename "$module_dir")" = scripts ]; then
  echo '構成が古い: go.mod が scripts/ 配下にある。' >&2
  echo "  見つかった go.mod: ${found}" >&2
  echo 'go.mod と go.sum はプロジェクト直下へ置く構成に変わっている。' >&2
  echo 'ビルド対象のブランチ／コミットが古い可能性が高い。' >&2
  exit 1
fi
if [ -f "$module_dir/scripts/go.mod" ]; then
  echo '構成が期待と違う: scripts/go.mod が残っている。' >&2
  echo 'モジュールはプロジェクト直下の go.mod だけである。scripts/go.mod は削除する。' >&2
  exit 1
fi

# ビルド対象のソースがあること（3 本とも）。
for required in scripts/generate_green_verification_report/main.go \
                scripts/collect_green_runtime_values/main.go \
                scripts/collect_green_runtime_values/rds-global-bundle.pem \
                scripts/collect_green_state/main.go; do
  if [ ! -f "$module_dir/$required" ]; then
    echo "構成が期待と違う: ${required} が無い。" >&2
    echo "モジュールルート: ${module_dir}" >&2
    ls -la "$module_dir" >&2 || true
    exit 1
  fi
done

# 依存は go.sum で固定する前提である（CI では go mod tidy をしない）。
if [ ! -f "$module_dir/go.sum" ]; then
  echo '構成が期待と違う: go.sum が無い。' >&2
  echo 'ローカルで go mod tidy を実行し、go.mod と go.sum の両方を commit する。' >&2
  exit 1
fi

# 標準出力にはモジュールルートだけを載せる（呼び出し側が $(...) で受ける）。
printf '%s\n' "$module_dir"
