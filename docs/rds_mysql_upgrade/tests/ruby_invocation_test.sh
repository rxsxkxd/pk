#!/usr/bin/env bash
# 呼び出し側のシェルが、Ruby の実装を **ruby へ明示的に渡して**呼んでいることを確認する。
# AWS へは接続しない（ファイルを読むだけ）。
#
# 直接実行（shebang 頼み）だと、CodePipeline のソースアーティファクトで実行ビットが
# 落ちたときに Permission denied（終了コード 126）で止まる。buildspec の chmod は
# .sh しか対象にしないため、.rb は必ず `ruby <パス>` で呼ぶ。
set -uo pipefail
cd "$(dirname "$0")/.."
failed=0

check_call() {  # $1=呼び出し側 $2=呼ばれる .rb（scripts/ からの相対パス）
  local caller=$1 target=$2
  if grep -qE "ruby \"\\\$\(dirname \"\\\$0\"\)/${target}\"" "$caller"; then
    printf 'ok    %s が ruby 経由で %s を呼ぶ\n' "$(basename "$caller")" "$target"
  else
    printf 'FAIL  %s が ruby 経由で %s を呼んでいない\n' "$(basename "$caller")" "$target"
    failed=$((failed + 1))
  fi
}
check_call scripts/build_green.sh create_blue_green_deployment.rb
check_call scripts/switchover.sh switchover_blue_green_deployment.rb
check_call scripts/verify_green.sh prepare_green_verification.rb
check_call scripts/verify_green.sh lib/resolve_green_tools.rb
check_call scripts/build_green.sh lib/migration_phase.rb
check_call scripts/switchover.sh lib/migration_phase.rb

# 呼ばれる .rb が実在すること（削除・改名の取り残しを防ぐ）。
for rb in create_blue_green_deployment switchover_blue_green_deployment prepare_green_verification collect_green_state collect_green_runtime_values check_target_parameter_group; do
  if [[ -f "scripts/${rb}.rb" ]] && ruby -c "scripts/${rb}.rb" >/dev/null 2>&1; then
    printf 'ok    scripts/%s.rb が存在し構文が正しい\n' "$rb"
  else
    printf 'FAIL  scripts/%s.rb が無いか構文エラー\n' "$rb"; failed=$((failed + 1))
  fi
done

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
