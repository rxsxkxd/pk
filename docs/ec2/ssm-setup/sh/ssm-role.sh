#!/usr/bin/env bash
# IAM ロールが未設定のインスタンスに、SSM 用のインスタンスプロファイルを関連付ける。
# すでにロールがある台には何もしない（ロールに権限を足すこともしない）。インスタンスプロファイルは用意しておく。
#   sh/ssm-role.sh [--instance-profile port-guard-ssm] [--check-only] [--yes] < instance-ids.txt
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
name=port-guard-ssm; check_only=; yes=
while [ $# -gt 0 ]; do
  case $1 in
    --instance-profile) name=$2; shift ;; --check-only) check_only=1 ;; --yes) yes=1 ;;
    *) sed -n 4p "$0" >&2; exit 2 ;;
  esac
  shift
done
read_ids
aws iam get-instance-profile --instance-profile-name "$name" >/dev/null  # なければ AWS のエラーを出して止まる
todo=; skipped=0
for id in $ids; do
  read -r state tag <<<"$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[State.Name,Tags[?Key==`Name`]|[0].Value]' --output text 2>/dev/null || echo 見つからない)"
  [ "${tag:-None}" = None ] && tag=
  arn=$(aws ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$id" \
    --query 'IamInstanceProfileAssociations[?State==`associated`||State==`associating`].IamInstanceProfile.Arn' --output text)
  if [ "$state" != running ] && [ "$state" != stopped ]; then echo "対象外      $id  ${tag:-}  （$state）"; skipped=1
  elif [ -n "$arn" ]; then echo "何もしない  $id  $tag  （$arn）"
  else echo "関連付ける  $id  $tag"; todo="$todo $id"; fi
done
[ -z "$check_only" ] && [ -n "$todo" ] || exit "$skipped"
[ -n "$yes" ] || ask "「関連付ける」の台に、インスタンスプロファイル $name を関連付けますか？" || { echo "中止した"; exit 0; }
failed=0
for id in $todo; do
  # 確かめた後にほかの人が関連付けていたら、AWS の側が拒む（IncorrectState）
  if aws ec2 associate-iam-instance-profile --instance-id "$id" --iam-instance-profile "Name=$name" >/dev/null; then
    echo "完了  $id"
  else
    echo "失敗  $id"; failed=1
  fi
done
echo "SSM に登録される（Online）まで数分かかることがある。少し時間を置いてから sh/ssm-check.sh で確かめる"
[ "$failed" = 0 ] && exit "$skipped" || exit 1
