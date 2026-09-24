#!/usr/bin/env bash
# Step 4 のビルド済みバイナリ 3 本の解決（scripts/lib/resolve_green_tools.rb）を確認する。
# AWS へも DB へも接続しない。
#
# 確認するのは 4 点である。
#   - 呼び出し側の指定 → artifact → ソースツリー の優先順で解決する
#   - 片方でも欠ければ終了コード 1 を返し、理由と探索先を出す
#   - 標準出力は eval できる KEY=値 の行だけで、診断は stderr へ出る
#   - 空白を含むパスでも eval して壊れない
set -uo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" == *"$expected"* ]]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %-54s 期待 "%s" が含まれない: %s\n' "$desc" "$expected" "${actual:0:200}"
    failed=$((failed + 1))
  fi
}
check_status() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" -eq "$expected" ]]; then
    printf 'ok    %s（exit=%s）\n' "$desc" "$actual"
  else
    printf 'FAIL  %-54s 期待 exit=%s 実際 exit=%s\n' "$desc" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

if ! command -v ruby >/dev/null 2>&1; then
  echo 'skip  Ruby が見つからない'; exit 0
fi

REL=.tools/green-report
GEN=generate_green_verification_report
COL=collect_green_runtime_values
STA=collect_green_state
make_tools() { mkdir -p "$1/$REL"; : > "$1/$REL/$GEN"; : > "$1/$REL/$COL"; : > "$1/$REL/$STA"; }

make_tools "$work/src"
make_tools "$work/artifact"
mkdir -p "$work/given"; : > "$work/given/$GEN"; : > "$work/given/$COL"; : > "$work/given/$STA"

run() { env -i PATH="$PATH" HOME="$HOME" "$@" ruby scripts/lib/resolve_green_tools.rb; }

# --- ① artifact を優先する（ソースツリーより先）-----------------------------
out=$(run CODEBUILD_SRC_DIR="$work/src" CODEBUILD_SRC_DIR_ReportToolOutput="$work/artifact" 2>"$work/e1"); status=$?
check_status 'artifact から解決できる' 0 "$status"
check 'artifact のパスを返す' "$work/artifact/$REL/$GEN" "$out"
check 'artifact から採ったと伝える' 'from the BuildReportTool artifact' "$(cat "$work/e1")"

# --- ② artifact が無ければソースツリー ---------------------------------------
out=$(run CODEBUILD_SRC_DIR="$work/src" 2>"$work/e2"); status=$?
check_status 'ソースツリーから解決できる' 0 "$status"
check 'ソースツリーのパスを返す' "$work/src/$REL/$COL" "$out"
check 'ソースツリーから採ったと伝える' 'found in the source tree' "$(cat "$work/e2")"

# --- ③ 呼び出し側の指定が最優先 ----------------------------------------------
out=$(run CODEBUILD_SRC_DIR="$work/src" CODEBUILD_SRC_DIR_ReportToolOutput="$work/artifact" \
          GREEN_REPORT_GENERATOR="$work/given/$GEN" 2>"$work/e3"); status=$?
check_status '呼び出し側の指定で解決できる' 0 "$status"
check '指定したパスを返す' "GREEN_REPORT_GENERATOR=$work/given/$GEN" "$out"
check '呼び出し側の指定だと伝える' 'given by the caller' "$(cat "$work/e3")"
check '他方はソース/artifact から解決する' "GREEN_RUNTIME_COLLECTOR=$work/artifact/$REL/$COL" "$out"

# --- ④ 標準出力は eval できる行だけ ------------------------------------------
lines=$(printf '%s\n' "$out" | grep -c .)
if [[ "$lines" -eq 3 ]]; then
  echo 'ok    標準出力は 3 行だけ（診断は stderr）'
else
  echo "FAIL  標準出力が 3 行でない: ${lines}"; failed=$((failed + 1))
fi
( eval "$out"; [[ -n "$GREEN_REPORT_GENERATOR" && -n "$GREEN_RUNTIME_COLLECTOR" && -n "$GREEN_STATE_COLLECTOR" ]] ) \
  && echo 'ok    eval して変数になる' || { echo 'FAIL  eval できない'; failed=$((failed + 1)); }

# --- ⑤ 片方だけ欠けていれば失敗 ----------------------------------------------
rm -f "$work/src/$REL/$COL"
run CODEBUILD_SRC_DIR="$work/src" >"$work/o5" 2>"$work/e5"; status=$?
check_status '収集バイナリが欠けていれば失敗' 1 "$status"
check '欠けている方を名指しする' 'The runtime value collector is absent' "$(cat "$work/e5")"
check '探索先を出す' "$work/src/$REL/$COL" "$(cat "$work/e5")"
check 'ビルドしない理由を出す' 'does not build it on purpose' "$(cat "$work/e5")"

# --- ⑥ 空白を含むパスでも壊れない --------------------------------------------
spaced="$work/dir with space"
make_tools "$spaced"
out=$(run CODEBUILD_SRC_DIR="$spaced" 2>/dev/null); status=$?
check_status '空白を含むパスでも解決できる' 0 "$status"
( eval "$out"; [[ "$GREEN_REPORT_GENERATOR" == "$spaced/$REL/$GEN" ]] ) \
  && echo 'ok    空白入りパスが eval 後も壊れない' \
  || { echo 'FAIL  空白入りパスが壊れた'; failed=$((failed + 1)); }

# --- ⑦ buildspec の受け取り方が失敗を捕まえるか ------------------------------
# eval "$(...)" と書くと Ruby の終了コードが eval のものに化けて素通りする。
# buildspec は変数へ受けてから eval しているので、ここで落ちる必要がある。
snippet=$(ruby -ryaml -e '
  d = YAML.safe_load(File.read("ci/codebuild/verify-green.yml"))
  puts d["phases"]["pre_build"]["commands"].find { |c| c.include?("resolve_green_tools.rb") }
')
( cd "$work" && mkdir -p empty && cd empty && CODEBUILD_SRC_DIR="$work/empty" \
  bash -c "cd '$OLDPWD'; $snippet" ) >/dev/null 2>&1
check_status 'buildspec の受け取りが失敗を捕まえる' 1 $?

# --- ⑧ --build-missing（verify_green.sh 用）----------------------------------
# 偽の go: 呼び出しを記録し、-o の先に空のファイルを作る。本物のビルドはしない。
mkdir -p "$work/gobin"
cat > "$work/gobin/go" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$work/go.log'
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && : > "\$2"; shift; done
EOF
chmod +x "$work/gobin/go"
run_build() { env -i PATH="$work/gobin:$PATH" HOME="$HOME" GREEN_TOOLS_BUILD_DIR="$work/built" "$@" \
  ruby scripts/lib/resolve_green_tools.rb --build-missing "$GEN"; }

rm -f "$work/go.log"
out=$(run_build GREEN_REPORT_GENERATOR="$work/given/$GEN" 2>/dev/null); status=$?
check_status '--build-missing: 指定があれば使う' 0 "$status"
check '--build-missing: 指定したパスを返す' "GREEN_REPORT_GENERATOR=$work/given/$GEN" "$out"
[[ ! -e "$work/go.log" ]] && echo 'ok    --build-missing: 指定があればビルドしない' \
  || { echo 'FAIL  --build-missing: 指定があるのにビルドした'; failed=$((failed + 1)); }

out=$(run_build 2>"$work/e8"); status=$?
check_status '--build-missing: 無ければビルドする' 0 "$status"
check '--build-missing: ビルド先のパスを返す' "GREEN_REPORT_GENERATOR=$work/built/$GEN" "$out"
check '--build-missing: 対象パッケージをビルドする' "./scripts/$GEN" "$(cat "$work/go.log" 2>/dev/null)"
check '--build-missing: ビルドしたと伝える' 'Building the report generator locally' "$(cat "$work/e8")"
lines=$(printf '%s\n' "$out" | grep -c .)
[[ "$lines" -eq 1 ]] && echo 'ok    --build-missing: 標準出力は指定した 1 本だけ' \
  || { echo "FAIL  --build-missing: 標準出力が ${lines} 行"; failed=$((failed + 1)); }

ruby_bin=$(ruby -e 'print RbConfig.ruby')
env -i PATH=/nonexistent HOME="$HOME" GREEN_TOOLS_BUILD_DIR="$work/built2" \
  "$ruby_bin" scripts/lib/resolve_green_tools.rb --build-missing "$GEN" >/dev/null 2>"$work/e9"; status=$?
check_status '--build-missing: Go が無ければ失敗' 1 "$status"
check '--build-missing: 渡し方を案内する' 'GREEN_REPORT_GENERATOR でビルド済みバイナリを渡すこと' "$(cat "$work/e9")"

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
