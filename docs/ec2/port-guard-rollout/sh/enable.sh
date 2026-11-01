#!/usr/bin/env bash
# 遮断を 1 台ずつ有効にする（SSM の Run Command）。台ごとに y/n/q で確かめ、自動で元に戻る予約を入れてから有効にし、
# SSM で引き続き入れるか・作業者の PC から 80・443 番が応答するかを確かめて、合格なら確定、不合格ならすぐに戻す。
#   sh/enable.sh --backup-label 2026-10 [--revert-minutes 10] [--yes] < ok.txt
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); remote=$here/../remote
. "$here/lib.sh"
label=; minutes=10; yes=
while [ $# -gt 0 ]; do
  case $1 in
    --backup-label) label=$2; shift ;; --revert-minutes) minutes=$2; shift ;; --yes) yes=1 ;;
    *) sed -n 4p "$0" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$label" ] || { echo "--backup-label が要る" >&2; exit 2; }
read_ids
run_id=$(date +%Y%m%d-%H%M%S); done_n=0; ng=0
for id in $ids; do
  ip=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text | awk '{ print ($1 != "None") ? $1 : $2 }')
  echo "== $id（$ip）"
  if [ -z "$yes" ]; then
    read -r -p "この台の遮断を有効にしますか？（$minutes 分後に自動で元に戻る予約を入れてから行う）[y/n/q]: " a </dev/tty
    case $a in y) ;; q) echo "残りを止めた"; ng=$((ng + 1)); break ;; *) echo "飛ばした"; ng=$((ng + 1)); continue ;; esac
  fi
  backup_ok "$id" port-guard-rollout-backup "$label" || { echo "行わない: 12 時間以内の使えるバックアップ（AMI）がない"; ng=$((ng + 1)); continue; }
  out=$(run_ssm "$id" "PG_RUN_ID=$run_id PG_REVERT_MINUTES=$minutes
$(cat "$remote/enable-preflight.sh" "$remote/enable-apply.sh")") && applied=1 || applied=
  echo "$out"
  revert=$(echo "$out" | sed -n 's/^PG revert=//p')
  [ -n "$revert" ] || { echo "有効にしていない"; ng=$((ng + 1)); continue; }
  problems=
  [ -n "$applied" ] || problems="有効化の途中で失敗した"
  run_ssm "$id" "echo PG reachable=yes" >/dev/null || problems="$problems SSM で入れなくなった"
  curl -s -o /dev/null -m 5 "http://$ip/" || problems="$problems 80 番が応答しない"
  curl -sk -o /dev/null -m 5 "https://$ip/" || problems="$problems 443 番が応答しない"
  if [ -n "$problems" ]; then
    echo "不合格:$problems。すぐに元に戻す（SSM で入れないときは $minutes 分後に予約で戻る）"
    run_ssm "$id" "PG_REVERT=$revert
$(cat "$remote/enable-revert.sh")" || true
    ng=$((ng + 1))
  elif run_ssm "$id" "PG_REVERT=$revert
$(cat "$remote/enable-confirm.sh")"; then echo "確定"; done_n=$((done_n + 1))
  else echo "予約の取り消しに失敗。$minutes 分後に自動で元に戻る"; ng=$((ng + 1)); fi
done
echo "== 結果: 確定 $done_n 台、確定していない $ng 台（実行の ID: $run_id）"
[ "$ng" = 0 ]
