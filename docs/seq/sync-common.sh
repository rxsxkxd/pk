#!/usr/bin/env bash
# 棚卸しツールの共通部分を、各ツール（*-inventory/）に写す。
#
#   ./sync-common.sh          写す
#   ./sync-common.sh --check  写さずに、正本と違うファイルを報告する（違いがあれば終了コード 1）
#
# 写すもの:
#   _common/shell/lib.sh                     → <ツール>/shell/lib.sh
#   _common/ruby/{sdk,cli}/inventory_common.rb → <ツール>/ruby/{sdk,cli}/
#   _common/ruby/entry.rb                    → <ツール>/ruby/{sdk,cli}/<ツール名>.rb
#   _common/python/inventory_common.py       → <ツール>/python/{sdk,cli}/
#   _common/python/{sdk,cli}/aws_client.py   → <ツール>/python/{sdk,cli}/
#   _common/python/entry.py                  → <ツール>/python/{sdk,cli}/<ツール名>.py
#   <ツール>/python/sdk/service.py            → <ツール>/python/cli/service.py（Python は SDK 版と CLI 版で同じ）
#   <ツール>/tables/*                         → <ツール>/{shell,ruby/sdk,ruby/cli,python/sdk,python/cli}/
set -euo pipefail

seq_dir=$(cd "$(dirname "$0")" && pwd)
common="$seq_dir/_common"
check=false
[ "${1:-}" = --check ] && check=true
status=0

copy() {
  local src=$1 dst=$2
  if $check; then
    cmp -s "$src" "$dst" || { echo "正本と違う: ${dst#"$seq_dir"/}"; status=1; }
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
}

for tool_dir in "$seq_dir"/*-inventory; do
  # 新しい構成（python/sdk/service.py がある）のツールだけを対象にする
  [ -f "$tool_dir/python/sdk/service.py" ] || continue
  tool=$(basename "$tool_dir")
  snake=${tool//-/_}

  copy "$common/shell/lib.sh" "$tool_dir/shell/lib.sh"
  for kind in sdk cli; do
    copy "$common/ruby/$kind/inventory_common.rb" "$tool_dir/ruby/$kind/inventory_common.rb"
    copy "$common/ruby/entry.rb" "$tool_dir/ruby/$kind/$snake.rb"
    copy "$common/python/inventory_common.py" "$tool_dir/python/$kind/inventory_common.py"
    copy "$common/python/$kind/aws_client.py" "$tool_dir/python/$kind/aws_client.py"
    copy "$common/python/entry.py" "$tool_dir/python/$kind/$snake.py"
  done
  copy "$tool_dir/python/sdk/service.py" "$tool_dir/python/cli/service.py"

  if [ -d "$tool_dir/tables" ]; then
    for table in "$tool_dir"/tables/*; do
      for impl in shell ruby/sdk ruby/cli python/sdk python/cli; do
        copy "$table" "$tool_dir/$impl/$(basename "$table")"
      done
    done
  fi

  $check || chmod +x "$tool_dir/shell/$tool.sh" "$tool_dir"/ruby/*/"$snake.rb" "$tool_dir"/python/*/"$snake.py"
done

exit $status
