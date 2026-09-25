#!/usr/bin/env bash
# Step 4 の状態収集（collect_green_state）の Go 実装と Ruby 実装が同じに振る舞うことを
# 確かめる。AWS へも DB へも接続しない（PATH 上の aws を偽物に差し替える）。
#
#   Go:   scripts/collect_green_state/（scripts/internal/greenstate）
#   Ruby: scripts/collect_green_state.rb（scripts/lib/green_state.rb）
#
# パイプラインは Ruby 版のロジック（lib/green_state.rb）を prepare_green_verification.rb から使い、Go 版は残してある。
# **どちらかを変えたら、もう一方へ同じ変更を入れる。**ずれるとこのテストが落ちる。
#
# 比べるもの: 終了コード・標準出力・標準エラー・書き出したファイル・AWS CLI の呼び出し引数。
# レポート生成器は Go のまま（CloudFormation の読み取り scripts/internal/cfn を実効値の
# 収集器と共有するため）で、Ruby 版は持たない。
# Go が未導入の環境ではスキップする。
set -uo pipefail
cd "$(dirname "$0")/.."

if ! command -v go >/dev/null 2>&1; then
  echo 'skip  Go（未導入）'; exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0
go build -o "$work/go-state" ./scripts/collect_green_state || exit 1
rb_state=(ruby scripts/collect_green_state.rb)

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %-58s %s\n' "$1" "$2"; failed=$((failed + 1)); }

# 同じ引数で両方を実行し、終了コード・標準出力・標準エラーを比べる。
# 第 2 引数が stderr なら標準エラーも比べ、status なら終了コードと標準出力だけを比べる。
compare_run() {
  local desc=$1 mode=$2; shift 2
  local go_cmd=() rb_cmd=()
  while [[ $1 != -- ]]; do go_cmd+=("$1"); shift; done; shift
  while [[ $1 != -- ]]; do rb_cmd+=("$1"); shift; done; shift
  "${go_cmd[@]}" "$@" >"$work/go.out" 2>"$work/go.err"; local go_status=$?
  "${rb_cmd[@]}" "$@" >"$work/rb.out" 2>"$work/rb.err"; local rb_status=$?
  if [[ $go_status -ne $rb_status ]]; then
    fail "$desc" "終了コード Go=$go_status Ruby=$rb_status / Go: $(head -c 200 "$work/go.err") / Ruby: $(head -c 200 "$work/rb.err")"; return 1
  fi
  if ! cmp -s "$work/go.out" "$work/rb.out"; then
    fail "$desc" "標準出力が違う: $(diff "$work/go.out" "$work/rb.out" | head -5)"; return 1
  fi
  if [[ $mode == stderr ]] && ! cmp -s "$work/go.err" "$work/rb.err"; then
    fail "$desc" "標準エラーが違う: $(diff "$work/go.err" "$work/rb.err" | head -5)"; return 1
  fi
  ok "${desc}（exit=${go_status}）"
}

# ===========================================================================
# 1. 状態の収集（collect_green_state）— PATH 上の aws を差し替える
# ===========================================================================
# 偽の aws は、呼ばれた引数に応じて同じディレクトリの応答ファイルを返す。
# 応答をファイルにしておくと、値に引用符が混じってもスクリプトの引用が崩れない。
#   source.json / deployments.json / green.json / empty.json（パラメータ）/ lag.json
#   fail … このファイルがあれば、中身を標準エラーへ出して 255 で終わる（AWS CLI の失敗）
make_fake_aws() {  # $1=ディレクトリ
  mkdir -p "$1"
  cat > "$1/aws" <<EOF
#!/bin/sh
d='$1'
printf '%s\n' "\$*" >> "\$d/calls.log"
if [ -f "\$d/fail" ]; then cat "\$d/fail" >&2; exit 255; fi
case "\$*" in
  *"describe-db-instances --db-instance-identifier blue "*) cat "\$d/source.json" ;;
  *describe-blue-green-deployments*) cat "\$d/deployments.json" ;;
  *describe-db-instances*) cat "\$d/green.json" ;;
  *describe-db-parameters*) cat "\$d/empty.json" ;;
  *get-metric-statistics*) cat "\$d/lag.json" ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$1/aws"
  printf '%s\n' '{"DBInstances":[{"DBInstanceArn":"arn:aws:rds:ap-northeast-1:1:db:blue"}]}' > "$1/source.json"
  printf '%s\n' '{"BlueGreenDeployments":[{"BlueGreenDeploymentIdentifier":"bgd-1","Target":"arn:aws:rds:ap-northeast-1:1:db:green-1","Status":"AVAILABLE"}]}' > "$1/deployments.json"
  printf '%s\n' '{"DBInstances":[{"Endpoint":{"Address":"green-1.example.rds.amazonaws.com"}}]}' > "$1/green.json"
  printf '%s\n' '{"Parameters":[]}' > "$1/empty.json"
  printf '%s\n' '{"Datapoints":[{"Maximum":0}]}' > "$1/lag.json"
}

compare_state() {  # $1=説明 $2=応答を書き換えるシェル断片（$fake が偽 aws のディレクトリ） 残り=追加引数
  local desc=$1 tweak=$2; shift 2
  local impl status=()
  for impl in go rb; do
    rm -rf "$work/state-$impl" "$work/aws-$impl"
    local fake="$work/aws-$impl"
    make_fake_aws "$fake"
    eval "$tweak"
    local cmd=("$work/go-state"); [[ $impl == rb ]] && cmd=("${rb_state[@]}")
    PATH="$fake:$PATH" "${cmd[@]}" --region ap-northeast-1 --source-id blue \
      --target-parameter-group pg-84 --output-dir "$work/state-$impl" "$@" \
      >"$work/$impl.out" 2>"$work/$impl.err"
    status+=($?)
    # 取得範囲の時刻は実行時刻に依存するので伏せる（範囲の幅は下で別に確かめる）。
    sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/<time>/g' "$fake/calls.log" > "$fake/calls.norm"
  done
  if [[ ${status[0]} -ne ${status[1]} ]]; then
    fail "$desc" "終了コード Go=${status[0]} Ruby=${status[1]} / Ruby: $(head -c 300 "$work/rb.err")"; return
  fi
  local what
  for what in out err; do
    cmp -s "$work/go.$what" "$work/rb.$what" || { fail "$desc" "std$what が違う: $(diff "$work/go.$what" "$work/rb.$what" | head -5)"; return; }
  done
  if ! cmp -s "$work/aws-go/calls.norm" "$work/aws-rb/calls.norm"; then
    fail "$desc" "AWS CLI の呼び出しが違う: $(diff "$work/aws-go/calls.norm" "$work/aws-rb/calls.norm" | head -6)"; return
  fi
  if [[ -d "$work/state-go" || -d "$work/state-rb" ]] && ! diff -r "$work/state-go" "$work/state-rb" >/dev/null 2>&1; then
    fail "$desc" "書き出したファイルが違う: $(diff -r "$work/state-go" "$work/state-rb" | head -6)"; return
  fi
  ok "${desc}（exit=${status[0]}）"
}

compare_state '収集: 正常' ':'
compare_state '収集: --profile を渡す' ':' --profile my-profile
compare_state '収集: 遅延を見る期間を変える' ':' --replica-lag-window 30m
compare_state '収集: Deployment が無い' \
  'printf "%s\n" "{\"BlueGreenDeployments\":[]}" > "$fake/deployments.json"'
compare_state '収集: AVAILABLE でない' \
  'sed -i.bak "s/AVAILABLE/PROVISIONING/" "$fake/deployments.json"'
compare_state '収集: 移行元が無い' \
  'printf "%s\n" "{\"DBInstances\":[]}" > "$fake/source.json"'
compare_state '収集: Target に :db: が無い' \
  'sed -i.bak "s/arn:aws:rds:ap-northeast-1:1:db:green-1/green-plain/" "$fake/deployments.json"'
compare_state '収集: AWS CLI の失敗' \
  'echo "An error occurred (AccessDenied) when calling the DescribeDBInstances operation" > "$fake/fail"'
compare_state '収集: 値に単一引用符を含む' \
  "sed -i.bak \"s/green-1.example/it'q'.example/\" \"\$fake/green.json\""

# 遅延を見る期間の幅（上では時刻を伏せたので、ここで幅だけ確かめる）。
make_fake_aws "$work/aws-window"
PATH="$work/aws-window:$PATH" "${rb_state[@]}" --region r --source-id blue --target-parameter-group pg \
  --output-dir "$work/state-window" >/dev/null 2>&1
window=$(grep get-metric-statistics "$work/aws-window/calls.log" | ruby -e '
  line = $stdin.read
  s = line[/--start-time (\S+)/, 1]; e = line[/--end-time (\S+)/, 1]
  require "time"; print((Time.iso8601(e) - Time.iso8601(s)).to_i)')
[[ "$window" == 600 ]] && ok 'Ruby: 遅延を見る期間は既定 10 分' || fail 'Ruby: 遅延を見る期間は既定 10 分' "実際 ${window} 秒"

# 必須引数は 1 つずつ欠かす。複数を同時に欠かすと、Go 版は map の走査順（ランダム）で
# 最初に報告する引数が変わり、比較が不定になるため。
full=(--region r --source-id blue --target-parameter-group pg --output-dir "$work/unused")
for missing in 0 2 4 6; do
  args=("${full[@]:0:missing}" "${full[@]:missing+2}")
  compare_run "収集: 必須引数なし（${full[missing]}）" stderr "$work/go-state" -- "${rb_state[@]}" -- "${args[@]}"
done

# ===========================================================================
# 2. パイプラインが Ruby 版のロジックを使っていること
# ===========================================================================
if grep -q "require_relative 'lib/green_state'" scripts/prepare_green_verification.rb; then
  ok 'prepare_green_verification.rb が lib/green_state.rb を使う'
else
  fail 'prepare_green_verification.rb が lib/green_state.rb を使っていない' ''
fi

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
