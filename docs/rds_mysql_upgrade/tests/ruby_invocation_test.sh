#!/usr/bin/env bash
# CI（buildspec・GitHub Actions）が、Ruby のエントリポイントを **ruby へ明示的に渡して**
# 呼んでいることを確認する。AWS へは接続しない（ファイルを読むだけ）。
#
# 直接実行（shebang 頼み）だと、CodePipeline のソースアーティファクトで実行ビットが
# 落ちたときに Permission denied（終了コード 126）で止まる。buildspec は chmod しないので、
# .rb は必ず `ruby <パス>` で呼ぶ。
set -uo pipefail
cd "$(dirname "$0")/.."
failed=0

check_call() {  # $1=呼び出し側 $2=呼ばれる .rb（リポジトリからの相対パス）
  local caller=$1 target=$2
  if grep -qF "ruby ${target}" "$caller"; then
    printf 'ok    %s が ruby 経由で %s を呼ぶ\n' "$caller" "$target"
  else
    printf 'FAIL  %s が ruby 経由で %s を呼んでいない\n' "$caller" "$target"
    failed=$((failed + 1))
  fi
}
check_call ci/codebuild/build-green.yml scripts/build_green.rb
check_call ci/codebuild/verify-green.yml scripts/verify_green.rb
check_call ci/codebuild/verify-green.yml scripts/lib/resolve_green_tools.rb
check_call ci/codebuild/switchover.yml scripts/switchover.rb
check_call ci/codebuild/precheck-target-parameter-group.yml scripts/check_target_parameter_group.rb
check_call ci/codebuild/read-approvals.yml scripts/lib/deployment_config.rb
check_call .github/workflows/build-green.yml scripts/build_green.rb
check_call .github/workflows/verify-green.yml scripts/verify_green.rb
check_call .github/workflows/switchover.yml scripts/switchover.rb

# .rb を ruby を介さずに呼んでいる行が無いこと（コメント行は除く）。
bare=$(grep -nE '^[^#]*[^[:alnum:]_/.]scripts/[A-Za-z0-9_/]+\.rb' ci/codebuild/*.yml .github/workflows/*.yml \
       | grep -vE 'ruby scripts/' || true)
if [[ -z "$bare" ]]; then
  echo 'ok    ruby を介さずに .rb を呼ぶ行が無い'
else
  printf 'FAIL  ruby を介さずに .rb を呼んでいる:\n%s\n' "$bare"; failed=$((failed + 1))
fi

# 呼ばれる .rb が実在し、構文が正しいこと（削除・改名の取り残しを防ぐ）。
for rb in build_green verify_green switchover collect_green_runtime_values check_target_parameter_group \
          lib/deployment_config lib/resolve_green_tools lib/migration_phase lib/green_state lib/aws_cli; do
  if [[ -f "scripts/${rb}.rb" ]] && ruby -c "scripts/${rb}.rb" >/dev/null 2>&1; then
    printf 'ok    scripts/%s.rb が存在し構文が正しい\n' "$rb"
  else
    printf 'FAIL  scripts/%s.rb が無いか構文エラー\n' "$rb"; failed=$((failed + 1))
  fi
done

# buildspec の chmod が指すファイルが実在すること。
# パターンに一致するファイルが無いと、bash はパターンをそのまま chmod へ渡して失敗し、
# buildspec の install フェーズごと落ちる（scripts/lib/*.sh を Ruby へ移した後に実際に起きかけた）。
while IFS= read -r pattern; do
  if compgen -G "$pattern" >/dev/null; then
    printf 'ok    buildspec の chmod %s に一致するファイルがある\n' "$pattern"
  else
    printf 'FAIL  buildspec の chmod %s に一致するファイルが無い\n' "$pattern"; failed=$((failed + 1))
  fi
done < <(grep -hE 'chmod \+x scripts/' ci/codebuild/*.yml | sed 's/.*chmod +x //' | tr ' ' '\n' | grep '^scripts/' | sort -u)

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
