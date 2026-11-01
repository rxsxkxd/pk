#!/usr/bin/env bash
# SSM で入れるかを確かめる（設定は変えない）。1 台ずつ、インスタンスプロファイル、ロールの AmazonSSMManagedInstanceCore、
# 登録（Online）、Run Command で echo が返るかを見て、「入れる」「SSM Agent で直す」「手で直す」に分ける。
#   sh/ssm-check.sh [--ok-out ok.txt] [--ng-out ng.txt] < instance-ids.txt
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
ok_out=/dev/null; ng_out=/dev/null
while [ $# -gt 0 ]; do
  case $1 in
    --ok-out) ok_out=$2; shift ;; --ng-out) ng_out=$2; shift ;;
    *) sed -n 4p "$0" >&2; exit 2 ;;
  esac
  shift
done
read_ids
q() { aws "$@" --output text 2>/dev/null || echo 読めない; }
ok=0; agent=0; manual=0
echo "# ssm-check で入れた台（フェーズ 2 の標準入力に渡せる）" > "$ok_out"
echo "# SSM Agent で直す台（バックアップと ssm-agent に渡せる）。手で直す台は行の先頭を # にして残す" > "$ng_out"
for id in $ids; do
  state=$(q ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name')
  profile=$(q ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$id" \
    --query 'IamInstanceProfileAssociations[?State==`associated`].IamInstanceProfile.Arn | [0]')
  role=なし; core=なし
  if [ "$profile" != None ] && [ "$profile" != 読めない ]; then
    role=$(q iam get-instance-profile --instance-profile-name "${profile##*/}" --query 'InstanceProfile.Roles[0].RoleName')
    [ "$(q iam list-attached-role-policies --role-name "$role" \
      --query 'length(AttachedPolicies[?PolicyName==`AmazonSSMManagedInstanceCore`])')" = 1 ] && core=あり
  fi
  ping=$(q ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" --query 'InstanceInformationList[0].PingStatus')
  echo "== $id  状態 $state  プロファイル ${profile##*/}  ロール $role（AmazonSSMManagedInstanceCore $core）  登録 $ping"
  if [ "$ping" = Online ] && run_ssm "$id" "echo PG ssm_check=ok" 20 2>/dev/null | grep -q 'PG ssm_check=ok'; then
    echo "   入れる"; echo "$id" >> "$ok_out"; ok=$((ok + 1))
  elif [ "$state" = running ] && [ "$core" = あり ] && [ "$ping" != Online ] && [ "$ping" != 読めない ]; then
    echo "   SSM Agent で直す"; echo "$id" >> "$ng_out"; agent=$((agent + 1))
  else
    if [ "$state" != running ]; then reason="状態が $state（running でない）"
    elif [ "$ping" = Online ]; then reason="Online なのに echo が返らない（ssmmessages への 443 番、作業者の権限、SSM Agent の版を見る）"
    elif [ "$ping" = 読めない ]; then reason="登録を読めない（作業者の権限 ssm:DescribeInstanceInformation を見る）"
    elif [ "$profile" = None ]; then reason="インスタンスプロファイルがない（ssm-role を見直す）"
    else reason="ロールに AmazonSSMManagedInstanceCore が付いていない、または読めない"; fi
    echo "   手で直す: $reason"; echo "# $id  # $reason" >> "$ng_out"; manual=$((manual + 1))
  fi
done
echo "== 結果: 入れる $ok 台、SSM Agent で直す $agent 台、手で直す $manual 台"
[ "$agent" = 0 ] && [ "$manual" = 0 ]
