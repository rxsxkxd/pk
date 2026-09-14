#!/usr/bin/env bash
# CloudFormation の短縮記法（!Ref / !Sub など）の解釈と、Step 4 レポートの
# 2 つの実行形態（MySQL 実効値あり／なし）を確認する。AWS へは接続しない。
#
# 短縮記法の実装は scripts/internal/cfn に一本化してあり、
# パラメータ名の列挙（list_db_parameter_names）とレポート生成器がどちらもこれを使う。
# 「短縮記法を長形式へ正規化し、組み込み関数の値は比較対象から外す」挙動である。
# Go が未導入の環境ではスキップする。
set -uo pipefail
cd "$(dirname "$0")/../.."

FIXTURE=examples/cfn-shorthand/mysql84-parameter-group-shorthand.yaml
LONGFORM=examples/mysql84-parameter-generation/output/mysql84-parameter-group.yaml
COLLECTED=examples/cfn-shorthand/collected
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" == *"$expected"* ]]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %-52s 期待 "%s" が含まれない: %s\n' "$desc" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

# --- internal/cfn: パラメータ名を抽出できること -----------------------------
# collect_green_runtime_values.sh が実効値収集の対象を決めるために使う経路である。
if command -v go >/dev/null 2>&1; then
  for template in "$FIXTURE" "$LONGFORM"; do
    if ! names=$(go run ./scripts/list_db_parameter_names --template "$template" 2>&1); then
      printf 'FAIL  %-52s %s\n' "internal/cfn: $(basename "$template")" "$names"
      failed=$((failed + 1)); continue
    fi
    check "internal/cfn: $(basename "$template") から名前を抽出" 'binlog_format' "$names"
  done
  # 組み込み関数で宣言した項目もパラメータ名としては拾う（実効値の収集対象になる）。
  names=$(go run ./scripts/list_db_parameter_names --template "$FIXTURE" 2>/dev/null)
  check 'internal/cfn: 組み込み関数の項目も名前は拾う' 'replica_parallel_workers' "$names"
else
  echo 'skip  internal/cfn（Go 未導入）'
fi

# --- レポート生成器: 組み込み関数を「比較不能」として扱うこと ----------------
report_args=(
  --template "$FIXTURE"
  --green-instance "$COLLECTED/green-db-instance.json"
  --deployment "$COLLECTED/deployment.json"
  --user-parameters "$COLLECTED/green-user-parameters.json"
  --system-parameters "$COLLECTED/green-system-parameters.json"
  --all-parameters "$COLLECTED/green-all-parameters.json"
  --replica-lag "$COLLECTED/replica-lag.json"
)

# レポート生成器は scripts/ 直下の package main で、internal/cfn を import する。
# リポジトリからそのままビルドする（依存は go.sum に固定済み）。
build_go() {
  go build -o "$work/gen" ./scripts >"$work/go.err" 2>&1
}

if command -v go >/dev/null 2>&1 && build_go; then
  if "$work/gen" "${report_args[@]}" --output "$work/go.md" 2>"$work/go.err"; then
    check 'Go: 組み込み関数は比較不能として出る' '比較不能（Ref）' "$(cat "$work/go.md")"
    check 'Go: 素のスカラーは通常どおり比較する' '| binlog_format | ROW | ROW | 一致' "$(cat "$work/go.md")"
    check 'Go: 誤ったドリフトを報告しない' '' "$(cat "$work/go.err")"
    # --- Step 4 の 2 つの実行形態を同じバイナリで賄えること -------------------
    # リモート（CI）は MySQL へ接続できない構成もありうるため、実効値なしでも
    # レポートを出せる必要がある。その場合は「未収集」と示す。
    check 'Go: MySQL 実効値なしでもレポートを出す（リモート）' \
      '| binlog_format | ROW | ROW | 一致 |  | 未収集 |' "$(cat "$work/go.md")"
    # ローカルは実効値を収集して同じバイナリへ渡す。列が埋まるだけで他は変わらない。
    if "$work/gen" "${report_args[@]}" --runtime-values "$COLLECTED/green-runtime-values.json" \
        --output "$work/go-mysql.md" 2>"$work/go.err"; then
      check 'Go: MySQL 実効値ありなら列が埋まる（ローカル）' \
        '| binlog_format | ROW | ROW | 一致 |  | ROW |' "$(cat "$work/go-mysql.md")"
      # 実効値の有無以外はレポートが変わらないこと（判定は AWS 側の値で行う）。
      if diff <(sed 's/| 未収集 |/| X |/' "$work/go.md") \
              <(sed -E 's/\| (ROW|ON|4|67108864) \| user \|/| X | user |/' "$work/go-mysql.md") \
              > "$work/mode.diff"; then
        echo 'ok    Go: 実効値の有無で変わるのは MySQL 実効値列だけ'
      else
        echo 'FAIL  Go: 実効値の有無で他の列も変わっている'; head -20 "$work/mode.diff"; failed=$((failed + 1))
      fi
    else
      printf 'FAIL  %-52s %s\n' 'Go: --runtime-values 付きで失敗した' "$(cat "$work/go.err")"
      failed=$((failed + 1))
    fi
  else
    printf 'FAIL  %-52s %s\n' 'Go: 短縮記法で失敗した' "$(cat "$work/go.err")"; failed=$((failed + 1))
  fi
else
  echo 'skip  Go（未導入、または依存を取得できずビルドできない）'
fi

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
