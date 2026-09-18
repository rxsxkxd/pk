#!/usr/bin/env bash
# Go モジュールルートの解決と構成検査（scripts/resolve_go_module_root.sh）を確認する。
# AWS へも Go へも依存しない（ファイル配置だけを見る）。
#
# この検査は CodeBuild の BuildReportTool が最初に通る関門である。
# 構成が期待から外れたときに**黙って別のものをビルドさせない**ことを固定する。
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
SCRIPT="$REPO/scripts/resolve_go_module_root.sh"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" == *"$expected"* ]]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %-50s 期待 "%s" が含まれない: %s\n' "$desc" "$expected" "${actual:0:180}"
    failed=$((failed + 1))
  fi
}
check_status() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" -eq "$expected" ]]; then
    printf 'ok    %s（exit=%s）\n' "$desc" "$actual"
  else
    printf 'FAIL  %-50s 期待 exit=%s 実際 exit=%s\n' "$desc" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

# 期待する構成を最小限で組み立てる。
make_layout() {
  local root=$1
  mkdir -p "$root/scripts/generate_green_verification_report" \
           "$root/scripts/collect_green_runtime_values" "$root/tools"
  printf 'module rds-mysql-upgrade\n\ngo 1.25\n' > "$root/go.mod"
  : > "$root/go.sum"
  : > "$root/scripts/generate_green_verification_report/main.go"
  : > "$root/scripts/collect_green_runtime_values/main.go"
  : > "$root/scripts/collect_green_runtime_values/rds-global-bundle.pem"
}

# --- ① 期待どおりの構成 -----------------------------------------------------
make_layout "$work/ok/proj"
out=$(CODEBUILD_SRC_DIR="$work/ok" bash "$SCRIPT" 2>"$work/e1"); status=$?
check_status '期待どおりなら成功' 0 "$status"
check 'モジュールルートを返す' "$work/ok/proj" "$out"
lines=$(printf '%s\n' "$out" | grep -c .)
[[ "$lines" -eq 1 ]] && echo 'ok    標準出力は 1 行だけ' \
  || { echo "FAIL  標準出力が 1 行でない: $lines"; failed=$((failed + 1)); }

# --- ② CODEBUILD_SRC_DIR がシンボリックリンク --------------------------------
# 実機の CODEBUILD_SRC_DIR は srcDownload/src へのシンボリックリンクである。
# find は起点がシンボリックリンクだと既定で辿らないため、ここが壊れやすい。
ln -s "$work/ok" "$work/link"
out=$(CODEBUILD_SRC_DIR="$work/link" bash "$SCRIPT" 2>/dev/null); status=$?
check_status 'シンボリックリンク起点でも解決できる' 0 "$status"
check 'リンク先の実体を返す' "/ok/proj" "$out"

# --- ③ 該当 go.mod が無い ----------------------------------------------------
mkdir -p "$work/empty"
CODEBUILD_SRC_DIR="$work/empty" bash "$SCRIPT" >"$work/o3" 2>"$work/e3"; status=$?
check_status 'go.mod が無ければ失敗' 1 "$status"
check '理由を出す' '構成が期待と違う: module rds-mysql-upgrade の go.mod が無い' "$(cat "$work/e3")"
check '探索した場所を出す' "$work/empty" "$(cat "$work/e3")"
[[ ! -s "$work/o3" ]] && echo 'ok    失敗時は標準出力へ何も出さない' \
  || { echo 'FAIL  失敗時に標準出力へ出している'; failed=$((failed + 1)); }

# --- ④ 別モジュールは拾わない ------------------------------------------------
mkdir -p "$work/other/probe"
printf 'module tzprobe\n' > "$work/other/probe/go.mod"
CODEBUILD_SRC_DIR="$work/other" bash "$SCRIPT" >/dev/null 2>"$work/e4"; status=$?
check_status 'module 名が違えば拾わない' 1 "$status"
check '見つかった go.mod を列挙する' 'probe/go.mod' "$(cat "$work/e4")"

# --- ⑤ 重複 -----------------------------------------------------------------
make_layout "$work/dup/a"; make_layout "$work/dup/b"
CODEBUILD_SRC_DIR="$work/dup" bash "$SCRIPT" >/dev/null 2>"$work/e5"; status=$?
check_status '複数あれば失敗' 1 "$status"
check '重複を指摘する' 'go.mod が複数ある' "$(cat "$work/e5")"

# --- ⑥ 旧構成（go.mod が scripts/ 配下）--------------------------------------
mkdir -p "$work/old/proj/scripts"
printf 'module rds-mysql-upgrade\n' > "$work/old/proj/scripts/go.mod"
CODEBUILD_SRC_DIR="$work/old" bash "$SCRIPT" >/dev/null 2>"$work/e6"; status=$?
check_status '旧構成なら失敗' 1 "$status"
check '古い構成だと名指しする' '構成が古い: go.mod が scripts/ 配下にある' "$(cat "$work/e6")"
check 'ブランチを疑うよう促す' 'ブランチ／コミットが古い' "$(cat "$work/e6")"

# --- ⑦ scripts/go.mod の残骸 -------------------------------------------------
make_layout "$work/stale/proj"
printf 'module rds-mysql-upgrade\n' > "$work/stale/proj/scripts/go.mod"
CODEBUILD_SRC_DIR="$work/stale" bash "$SCRIPT" >/dev/null 2>"$work/e7"; status=$?
check_status 'scripts/go.mod が残っていれば失敗' 1 "$status"
check '残骸を指摘する' 'go.mod が複数ある' "$(cat "$work/e7")"

# --- ⑧ ビルド対象のソース欠落 ------------------------------------------------
for missing in scripts/generate_green_verification_report/main.go \
               scripts/collect_green_runtime_values/main.go \
               scripts/collect_green_runtime_values/rds-global-bundle.pem \
               go.sum; do
  rm -rf "$work/miss"; make_layout "$work/miss/proj"; rm -f "$work/miss/proj/$missing"
  CODEBUILD_SRC_DIR="$work/miss" bash "$SCRIPT" >/dev/null 2>"$work/e8"; status=$?
  if [[ "$status" -ne 1 ]]; then
    printf 'FAIL  %-50s 期待 exit=1 実際 exit=%s\n' "$missing の欠落を検出" "$status"
    failed=$((failed + 1))
  else
    check "${missing} の欠落を検出" '構成が期待と違う' "$(cat "$work/e8")"
  fi
done

# --- ⑨ 実リポジトリで通ること ------------------------------------------------
out=$(cd "$REPO" && bash "$SCRIPT" 2>/dev/null); status=$?
check_status '実リポジトリの構成は期待どおり' 0 "$status"
check '実リポジトリのルートを返す' "$REPO" "$out"

# --- ⑩ buildspec の受け取り方が失敗を捕まえるか ------------------------------
snippet=$(ruby -ryaml -e '
  d = YAML.safe_load(File.read("ci/codebuild/build-report-tool.yml"))
  puts d["phases"]["pre_build"]["commands"].find { |c| c.include?("resolve_go_module_root.sh") }
')
( cd "$REPO" && CODEBUILD_SRC_DIR="$work/empty" bash -c "$snippet" ) >/dev/null 2>&1
check_status 'buildspec の受け取りが失敗を捕まえる' 1 $?

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
