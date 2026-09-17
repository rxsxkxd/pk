#!/usr/bin/env bash
# Step 1 の成立条件チェック（tools/evaluate_blue_green_prereqs.rb）を確認する。
# AWS へは接続しない。examples/blue-green-prereqs/ の匿名化済み入力を使う。
#
# 確認するのは 4 点である。
#   - --output を省略しても従来どおり動く（ファイルを作らない・標準出力の書式が同じ）
#   - --output でゲート①の判断材料レポートを出せる（ゴールデンと一致する）
#   - STOP があれば終了コード 1 になり、レポートにも STOP 節が出る
#   - 判定の根拠（観測値と取得元）がレポートに載る
set -uo pipefail
cd "$(dirname "$0")/.."

INPUT=examples/blue-green-prereqs/input
GOLDEN=examples/blue-green-prereqs/output/prereqs-evaluation-report.md
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" == *"$expected"* ]]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %-52s 期待 "%s" が含まれない\n' "$desc" "$expected"
    failed=$((failed + 1))
  fi
}

if ! command -v ruby >/dev/null 2>&1; then
  echo 'skip  Ruby が見つからない'; exit 0
fi

# --- ① --output 省略時 ------------------------------------------------------
stdout_only=$(ruby tools/evaluate_blue_green_prereqs.rb --input-dir "$INPUT" 2>&1)
status=$?
check '省略時: 終了コード 0（STOP なし）' '' "$status"
[[ "$status" -eq 0 ]] || { echo "FAIL  省略時の終了コードが 0 でない: $status"; failed=$((failed + 1)); }
check '省略時: 従来の集計行が出る' '結果: STOP=0, REVIEW=2' "$stdout_only"
if [[ "$stdout_only" == *"Report:"* ]]; then
  echo 'FAIL  --output 省略時に Report 行が出ている'; failed=$((failed + 1))
else
  echo 'ok    省略時: レポートを書き出さない'
fi

# --- ② --output 付き。標準出力は変わらないこと ------------------------------
with_output=$(ruby tools/evaluate_blue_green_prereqs.rb --input-dir "$INPUT" --output "$work/report.md" 2>&1)
if diff <(printf '%s\n' "$stdout_only") <(printf '%s\n' "$with_output" | grep -v '^Report: ') >/dev/null; then
  echo 'ok    --output を付けても標準出力の書式は変わらない'
else
  echo 'FAIL  --output で標準出力の書式が変わった'; failed=$((failed + 1))
fi

# --- ③ ゴールデンとの一致 ---------------------------------------------------
if diff -u "$GOLDEN" "$work/report.md" > "$work/golden.diff"; then
  echo 'ok    レポートがゴールデンと一致する'
else
  echo 'FAIL  レポートがゴールデンと差分あり'; head -30 "$work/golden.diff"; failed=$((failed + 1))
fi

# --- ④ 判断材料（観測値と取得元）が載ること ---------------------------------
report=$(cat "$work/report.md")
check '判断材料: 観測値が載る' 'BackupRetentionPeriod=7' "$report"
check '判断材料: 取得元が載る' '`db-parameters.json`' "$report"
check '判断材料: 判定が載る' '**移行可能**（STOP なし）' "$report"
check '判断材料: 集計が載る' 'PASS 12 件 / REVIEW 2 件 / STOP 0 件' "$report"
check '判断材料: REVIEW 節が出る' '## REVIEW — 人の確認が要る' "$report"

# --- ⑤ STOP があるケース ----------------------------------------------------
cp -R "$INPUT" "$work/stop-input"
ruby -rjson -e '
  path = ARGV[0] + "/db-instance.json"
  document = JSON.parse(File.read(path))
  document["DBInstances"][0]["BackupRetentionPeriod"] = 0
  File.write(path, JSON.generate(document))
' "$work/stop-input"
ruby tools/evaluate_blue_green_prereqs.rb --input-dir "$work/stop-input" --output "$work/stop.md" >/dev/null 2>&1
status=$?
if [[ "$status" -eq 1 ]]; then
  echo 'ok    STOP があれば終了コード 1'
else
  echo "FAIL  STOP があるのに終了コードが $status"; failed=$((failed + 1))
fi
stop_report=$(cat "$work/stop.md")
check 'STOP: 判定が移行不可になる' '**移行不可**（STOP 1 件）' "$stop_report"
check 'STOP: STOP 節が出る' '## STOP — 解消しないと移行できない' "$stop_report"
check 'STOP: 該当項目と観測値が出る' '**0-1-01 自動バックアップ** … BackupRetentionPeriod=0' "$stop_report"

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
