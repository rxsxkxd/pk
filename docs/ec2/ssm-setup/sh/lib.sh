# sh/ の道具の共通の部品（source して使う）。port-guard-rollout/sh/lib.sh と同じもの。
# AWS CLI の認証情報・リージョンは、AWS CLI の設定（AWS_PROFILE・AWS_REGION など）をそのまま使う。

# 標準入力から、インスタンスの ID を 1 行に 1 つ読む（# から後と空の行は無視。2 列目があっても使わない）
read_ids() {
  ids=$(sed 's/#.*//' | awk 'NF { print $1 }' | grep -E '^i-[0-9a-f]{8}([0-9a-f]{9})?$' | awk '!seen[$0]++' || true)
  [ -n "$ids" ] || { echo "インスタンスの ID がない（標準入力に 1 行 1 つで渡す）" >&2; exit 2; }
}

# 端末から y を受けたら 0（標準入力はインスタンスの一覧に使っているため、/dev/tty から読む）
ask() { local a; read -r -p "$1 [y/N]: " a </dev/tty || return 1; [ "$a" = y ]; }

# SSM の Run Command で、スクリプトを root として実行する（run_ssm <ID> <スクリプト> [待つ回数。3 秒ごと。既定 320]）。
# 標準出力を表示し、終了コードを返す（届かない・待ちきれないときは 255）
run_ssm() {
  local id=$1 b64 cid status=Pending
  b64=$(printf '%s' "$2" | base64 | tr -d '\n')
  cid=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript --comment "$(basename "$0")" \
    --parameters "{\"commands\":[\"echo $b64 | base64 -d | bash\"],\"executionTimeout\":[\"900\"]}" \
    --query Command.CommandId --output text) || return 255
  for _ in $(seq "${3:-320}"); do
    sleep 3
    status=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null) || continue
    case $status in Pending|InProgress|Delayed) continue ;; esac
    break
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text
  [ "$status" = Success ] && return 0
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardErrorContent --output text >&2
  [ "$status" = Failed ] && return 1 || return 255
}

# バックアップ（AMI）があるか: タグ Purpose・SourceInstanceId・BackupLabel が合い、作成が終わっていて、12 時間以内のもの
backup_ok() {  # backup_ok <インスタンスの ID> <Purpose の値> <BackupLabel の値>
  local since
  since=$(date -u -v-12H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '-12 hours' +%Y-%m-%dT%H:%M:%S)
  [ "$(aws ec2 describe-images --owners self --filters "Name=tag:Purpose,Values=$2" "Name=tag:SourceInstanceId,Values=$1" \
    "Name=tag:BackupLabel,Values=$3" Name=state,Values=available \
    --query "length(Images[?CreationDate>='$since'])" --output text)" != 0 ]
}
