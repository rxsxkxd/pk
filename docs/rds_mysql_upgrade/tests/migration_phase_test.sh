#!/usr/bin/env bash
# resolve_migration_phase のテーブル駆動テスト。AWS へは接続しない。
#
# 実行: tests/migration_phase_test.sh
# 不適合が 1 件でもあれば終了コード 1 を返す。
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=../scripts/lib/migration_phase.sh
source scripts/lib/migration_phase.sh

SOURCE_VERSION='8.0'
SOURCE_GROUP='svc-prod-mysql80-v1'
TARGET_VERSION='8.4.10'
TARGET_GROUP='svc-prod-mysql84-v1'

failed=0
check() {
  local description=$1 current_version=$2 current_group=$3 expected=$4
  local actual
  actual=$(resolve_migration_phase "$current_version" "$current_group" \
    "$SOURCE_VERSION" "$SOURCE_GROUP" "$TARGET_VERSION" "$TARGET_GROUP")
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok    %-52s -> %s\n' "$description" "$actual"
  else
    printf 'FAIL  %-52s -> %s (expected %s)\n' "$description" "$actual" "$expected"
    failed=$((failed + 1))
  fi
}

# 正常系
check '移行前（宣言どおり）'            '8.0.44' "$SOURCE_GROUP" pre_switchover
check '移行後（宣言どおり）'            '8.4.10' "$TARGET_GROUP" post_switchover

# パッチバージョンのドリフト。major.minor への正規化で吸収できることを確認する。
# 厳密一致や前方一致にすると RDS の自動マイナーバージョンアップグレードで止まる。
# とくに target は 8.4.10 と完全指定するため、前方一致では 8.4.11 を弾いてしまう。
check '移行前・自動パッチ更新後'        '8.0.46' "$SOURCE_GROUP" pre_switchover
check '移行後・自動パッチ更新後'        '8.4.11' "$TARGET_GROUP" post_switchover
check '移行後・パッチが下位'            '8.4.9'  "$TARGET_GROUP" post_switchover

# 異常系。いずれも unknown とし、呼び出し側で失敗させる。
check 'バージョンだけ移行後'            '8.4.10' "$SOURCE_GROUP" unknown
check 'パラメータグループだけ移行後'    '8.0.44' "$TARGET_GROUP" unknown
check '想定外のバージョン'              '5.7.44' "$SOURCE_GROUP" unknown
check '想定外のパラメータグループ'      '8.0.44' 'default.mysql8.0' unknown
check '空のパラメータグループ'          '8.0.44' ''               unknown

# major.minor 正規化の境界。前方一致では 8.04 が 8.0 に誤って一致していた。
check '8.04 は 8.0 と区別される'        '8.04.0' "$SOURCE_GROUP" unknown
check 'メジャーだけの宣言との比較'      '8.0.44' "$SOURCE_GROUP" pre_switchover

# 正規化そのものの確認
normalize_check() {
  local input=$1 expected=$2 actual
  actual=$(migration_phase_major_minor "$input")
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok    %-52s -> %s\n' "major_minor($input)" "$actual"
  else
    printf 'FAIL  %-52s -> %s (expected %s)\n' "major_minor($input)" "$actual" "$expected"
    failed=$((failed + 1))
  fi
}
normalize_check '8.0.44' '8.0'
normalize_check '8.4.10' '8.4'
normalize_check '8.0'    '8.0'
normalize_check '8'      '8'
normalize_check '8.04.0' '8.04'

echo
if [[ "$failed" -eq 0 ]]; then
  echo 'すべて期待どおり。'
  exit 0
fi
echo "不適合: ${failed} 件" >&2
exit 1
