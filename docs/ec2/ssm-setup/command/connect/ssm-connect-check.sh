#!/bin/bash
# SSM で実際に入れるかを、害のないコマンド（echo）を 1 回だけ流して確かめる（接続の確認。設定は変えない）。
#
#   bash command/connect/ssm-connect-check.sh [--via session|run-command] [--timeout 60] [--ok-out ok.txt] [--ng-out connect-ng.txt]
#                                             [--profile NAME] [--region REGION] < enabled.txt
#
# 作業者の PC と踏み台サーバーで、同じスクリプトを同じ形で流す（作業者の PC から入れても、踏み台サーバーから入れるとは限らない）。
# 事前の確認はしない。rb/ssm_check.rb の --ok-out（SSM 有効の台）を渡す想定。
# 確かめ方は 2 つで、--via を省くと両方を確かめる（IAM の権限が別のアクションで、片方だけ許されていることがあるため）。
# - session: Session Manager（AWS-StartNonInteractiveCommand）。session-manager-plugin が要る。権限は ssm:StartSession
# - run-command: Run Command（AWS-RunShellScript）。権限は ssm:SendCommand・ssm:GetCommandInvocation
# 確かめた経路のすべてで入れた台を --ok-out に、どれかで入れなかった台を、理由と一緒に --ng-out に書き出す
# （--ng-out の行は # で消していないので、直した後にそのまま渡し直せる）。セッションやコマンドの履歴は AWS の側に残る。
# 依るもの: bash（macOS の 3.2 でも動く書き方）、AWS CLI（v2）、session-manager-plugin（session のとき）。jq などは使わない。
# --profile・--region を付けると、すべての aws の呼び出しに付ける。付けなければ、AWS CLI の設定
# （AWS_PROFILE・AWS_REGION など。踏み台サーバーではインスタンスプロファイル）をそのまま使う。
# 終了コード: 0 = すべての台に入れる、1 = 入れない台がある、2 = 入力・道具の問題。
set -u
export AWS_PAGER=""

vias="session run-command"
timeout=60
ok_out=""
ng_out=""
profile=""
region=""
hint="ssmmessages・ec2messages への送信の 443 番、この場所の認証情報と権限（ssm:StartSession・ssm:SendCommand）、SSM Agent の版を見る"

usage() { echo "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --via) case "${2:-}" in session|run-command) vias="$2" ;; *) usage "--via は session か run-command" ;; esac; shift 2 ;;
    --timeout) case "${2:-}" in ''|*[!0-9]*) usage "--timeout は秒の数" ;; *) timeout="$2" ;; esac; shift 2 ;;
    --ok-out) ok_out="${2:?--ok-out にファイルの名前が要る}"; shift 2 ;;
    --ng-out) ng_out="${2:?--ng-out にファイルの名前が要る}"; shift 2 ;;
    --profile) profile="${2:?--profile にプロファイルの名前が要る}"; shift 2 ;;
    --region) region="${2:?--region にリージョンが要る}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) usage "知らない指定: $1" ;;
  esac
done

command -v aws >/dev/null 2>&1 || usage "aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）"
case " $vias " in
  *" session "*)
    command -v session-manager-plugin >/dev/null 2>&1 ||
      usage "session-manager-plugin が見つからない（Session Manager の確認に要る。入れて PATH を通すか、--via run-command で Run Command だけを確かめる）" ;;
esac

# 標準入力から、インスタンスの ID を 1 行に 1 つ読む（# から後と空の行は無視。2 列目があっても使わない。同じ ID は 1 回だけ）
ids=""
while IFS= read -r line || [ -n "$line" ]; do
  id=$(printf '%s\n' "${line%%#*}" | awk '{print $1}')
  [ -z "$id" ] && continue
  if ! printf '%s\n' "$id" | grep -Eq '^i-[0-9a-f]{8}([0-9a-f]{9})?$'; then
    echo "形式が正しくないので無視する: $id" >&2
    continue
  fi
  case " $ids " in *" $id "*) ;; *) ids="$ids $id" ;; esac
done
[ -n "$ids" ] || usage "インスタンスの ID がない（標準入力に 1 行 1 つで渡す）"

# aws を呼ぶ。--profile・--region が指定されていれば、最後に付ける（空の配列を使わないのは、bash 3.2 の set -u で止まるため）
aws_cmd() {
  [ -n "$profile" ] && set -- "$@" --profile "$profile"
  [ -n "$region" ] && set -- "$@" --region "$region"
  aws "$@"
}

# コマンドを、時間を決めて実行する（macOS には timeout のコマンドがないため）。標準出力と標準エラーは $out_file に
run_limited() {
  "$@" > "$out_file" 2>&1 < /dev/null &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "${timeout} 秒で終わらなかった" >> "$out_file"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

last_line() { grep -v '^[[:space:]]*$' "$1" | tail -n 1; }

# Session Manager で echo を流す。入れれば何も出さず 0、入れなければ理由を出して 1
try_session() {
  local id=$1 marker=$2
  run_limited aws_cmd ssm start-session --target "$id" --document-name AWS-StartNonInteractiveCommand \
    --parameters "{\"command\":[\"echo $marker\"]}"
  grep -q "$marker" "$out_file" && return 0
  echo "session: つながらない（$(last_line "$out_file")）"
  return 1
}

# Run Command で echo を流して、結果を待つ。入れれば何も出さず 0、入れなければ理由を出して 1
try_run_command() {
  local id=$1 marker=$2 command_id status waited=0
  if ! command_id=$(aws_cmd ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
      --comment ssm-connect-check --parameters "{\"commands\":[\"echo $marker\"]}" \
      --query Command.CommandId --output text 2>&1 < /dev/null); then
    echo "run-command: 送れない（$(printf '%s\n' "$command_id" | tail -n 1)）"
    return 1
  fi
  while [ "$waited" -lt "$timeout" ]; do
    sleep 3
    waited=$((waited + 3))
    # 送った直後は、まだ結果の記録がない（失敗しても待ち続ける）
    status=$(aws_cmd ssm get-command-invocation --command-id "$command_id" --instance-id "$id" \
      --query '[Status,StandardOutputContent]' --output text 2>/dev/null < /dev/null) || continue
    case "$status" in
      Pending*|InProgress*|Delayed*) continue ;;
    esac
    printf '%s\n' "$status" | grep -q "$marker" && return 0
    echo "run-command: つながらない（$(printf '%s\n' "$status" | head -n 1 | awk '{print $1}')、$command_id）"
    return 1
  done
  echo "run-command: ${timeout} 秒で結果が出なかった（$command_id）"
  return 1
}

out_file=$(mktemp)
trap 'rm -f "$out_file"' EXIT

count=$(printf '%s\n' $ids | wc -l | tr -d ' ')
echo "$count 台に SSM で echo を流す（確かめ方: $vias。この場所: $(hostname)。設定は変えない）"
connected=""
failed_lines=""
for id in $ids; do
  problems=""
  for via in $vias; do
    marker="ssm-setup-connect-$RANDOM$RANDOM"
    if [ "$via" = session ]; then
      problem=$(try_session "$id" "$marker") || problems="${problems:+$problems / }$problem"
    else
      problem=$(try_run_command "$id" "$marker") || problems="${problems:+$problems / }$problem"
    fi
  done
  if [ -z "$problems" ]; then
    echo "  入れる    $id"
    connected="$connected $id"
  else
    echo "  入れない  $id  $problems"
    failed_lines="$failed_lines$id  # $problems
"
  fi
done

ok_count=$(printf '%s\n' $connected | grep -c . || true)
ng_count=$(printf '%s' "$failed_lines" | grep -c . || true)
echo
echo "== 結果: 入れる $ok_count 台、入れない $ng_count 台（この場所: $(hostname)）"
[ "$ng_count" -gt 0 ] && echo "入れない台は、$hint"

if [ -n "$ok_out" ]; then
  { echo "# ssm-connect-check.sh で、$(hostname) から $vias で入れた台"; printf '%s\n' $connected | grep . || true; } > "$ok_out"
  echo "入れる台の一覧を書き出した: $ok_out（$ok_count 台）"
fi
if [ -n "$ng_out" ]; then
  { echo "# ssm-connect-check.sh で、$(hostname) から入れなかった台（直した後に、もう一度渡せる）。$hint"; printf '%s' "$failed_lines"; } > "$ng_out"
  echo "入れない台の一覧を書き出した: $ng_out（$ng_count 台）"
fi
[ "$ng_count" -eq 0 ]
