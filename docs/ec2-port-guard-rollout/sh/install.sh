#!/usr/bin/env bash
# ipset の導入と設定を、SSM の Run Command で 1 台ずつ行う（遮断はまだ効かせない）。
# 入れてよいかはインスタンスの側で確かめ（remote/install-preflight.sh）、問題があれば何もせずに理由を出す。
#   sh/install.sh --backup-label 2026-10 [--allow-file allow.txt] [--include-ssh] [--check-only] [--yes] < ok.txt
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); remote=$here/../remote
. "$here/lib.sh"
label=; allow=; ports=80,443; check_only=; yes=
while [ $# -gt 0 ]; do
  case $1 in
    --backup-label) label=$2; shift ;; --allow-file) allow=$2; shift ;; --include-ssh) ports=22,80,443 ;;
    --check-only) check_only=1 ;; --yes) yes=1 ;;
    *) sed -n 4p "$0" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$label" ] || { echo "--backup-label が要る" >&2; exit 2; }
read_ids
b64() { base64 < "$1" | tr -d '\n'; }
script=$(cat "$remote/install-preflight.sh")
if [ -z "$check_only" ]; then
  script="PG_PORTS=$ports PG_JP_MIN_ENTRIES=1000 PG_CHECK_IN_JP= PG_CHECK_OUTSIDE=
PG_ALLOW_B64=$(if [ -n "$allow" ]; then b64 "$allow"; fi) PG_APPLY_B64=$(b64 "$remote/port-guard-apply")
PG_UPDATE_JP_B64=$(b64 "$remote/port-guard-update-jp") PG_SERVICE_B64=$(b64 "$remote/port-guard.service")
$script
$(cat "$remote/install.sh")"
  echo "対象: $(echo $ids)（ポート $ports。許可する IP: ${allow:-なし}）"
  [ "$ports" = 80,443 ] || echo "注意: 22 番（SSH）も対象にする。日本の IP か許可する IP からしか SSH で入れなくなる"
  [ -n "$yes" ] || ask "上の台に ipset の導入と設定を試行しますか？" || { echo "中止した"; exit 0; }
fi
ok=0; ng=0
for id in $ids; do
  echo "== $id"
  if ! backup_ok "$id" port-guard-rollout-backup "$label"; then
    echo "行わない: バックアップ作業のタイミング「$label」の、12 時間以内の使えるバックアップ（AMI）がない"; ng=$((ng + 1)); continue
  fi
  if run_ssm "$id" "$script"; then ok=$((ok + 1)); else ng=$((ng + 1)); fi
done
echo "== 結果: 済んだ $ok 台、失敗・入れられない $ng 台"
[ "$ng" = 0 ]
