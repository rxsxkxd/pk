#!/usr/bin/env bash
# CloudFormation の短縮記法（!Ref / !Sub など）を、テンプレートを読む 3 実装が
# 同じように解釈することを確認する。AWS へは接続しない。
#
#   scripts/internal/cfn                     (Go / gopkg.in/yaml.v3。共有ライブラリ)
#   generate_green_verification_report.rb    (Ruby / Psych)
#   generate_green_verification_report.go    (Go。Docker で単体ビルドするため自前実装)
#
# いずれも「短縮記法を長形式へ正規化し、組み込み関数の値は比較対象から外す」挙動である。
# Ruby / Go が未導入の環境では、その実装をスキップする。
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

if command -v ruby >/dev/null 2>&1; then
  if ruby scripts/generate_green_verification_report.rb "${report_args[@]}" --output "$work/ruby.md" 2>"$work/ruby.err"; then
    body=$(cat "$work/ruby.md")
    check 'Ruby: 組み込み関数は比較不能として出る' '比較不能（Ref）' "$body"
    check 'Ruby: 素のスカラーは通常どおり比較する' '| binlog_format | ROW | ROW | 一致' "$body"
    check 'Ruby: 誤ったドリフトを報告しない' '' "$(cat "$work/ruby.err")"
  else
    printf 'FAIL  %-52s %s\n' 'Ruby: 短縮記法で失敗した' "$(cat "$work/ruby.err")"; failed=$((failed + 1))
  fi
else
  echo 'skip  Ruby（未導入）'
fi

# レポート生成器は scripts/ 直下の package main である（同ディレクトリの他コマンドは
# サブパッケージ）。単体ビルドするため一時ディレクトリへ写して組む。
# 依存は go.sum に固定済みで、モジュールキャッシュがあればオフラインで通る。
build_go() {
  mkdir -p "$work/go"
  cp go.mod go.sum scripts/generate_green_verification_report.go "$work/go/" || return 1
  ( cd "$work/go" && go build -o "$work/gen" . ) >"$work/go.err" 2>&1
}

if command -v go >/dev/null 2>&1 && build_go; then
  if "$work/gen" "${report_args[@]}" --output "$work/go.md" 2>"$work/go.err"; then
    check 'Go: 組み込み関数は比較不能として出る' '比較不能（Ref）' "$(cat "$work/go.md")"
    # Ruby 版と Go 版はレポート全文が一致していなければならない
    # （CLAUDE.md の「両方を同時に更新すること」を担保する）。
    if [[ -f "$work/ruby.md" ]]; then
      if diff -u "$work/ruby.md" "$work/go.md" > "$work/report.diff"; then
        echo 'ok    Ruby と Go のレポートが全文一致する'
      else
        echo 'FAIL  Ruby と Go のレポートが不一致'; head -20 "$work/report.diff"; failed=$((failed + 1))
      fi
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
