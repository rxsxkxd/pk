#!/usr/bin/env bash
# レポート生成器の検証機能（--check）を確認する。AWS へも DB へも接続しない。
#
# 突き合わせ（engine / instance class / パラメータグループの関連付けと適用状態 /
# ReplicaLag）は以前 verify_green.sh が担っていた。Go へ移したので、
# **同じ判定がバイナリ側で効くこと**をここで固定する。
#
# 確認するのは 4 点である。
#   - --output / --check / 両方 / どちらも無し、の 4 モード
#   - 宣言値と実状態が食い違えば終了コード 1 になり、理由が stderr に出る
#   - 不適合はレポートの「0. 検証結果」にも出る（内容と終了コードが食い違わない）
#   - --check を付けなければ検証節は出ず、従来どおりの出力になる
set -uo pipefail
cd "$(dirname "$0")/.."

C=examples/cfn-shorthand/collected
T=examples/cfn-shorthand/mysql84-parameter-group-shorthand.yaml
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" == *"$expected"* ]]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %-54s 期待 "%s" が含まれない: %s\n' "$desc" "$expected" "${actual:0:160}"
    failed=$((failed + 1))
  fi
}
check_status() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" -eq "$expected" ]]; then
    printf 'ok    %s（exit=%s）\n' "$desc" "$actual"
  else
    printf 'FAIL  %-54s 期待 exit=%s 実際 exit=%s\n' "$desc" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

if ! command -v go >/dev/null 2>&1; then
  echo 'skip  Go（未導入）'; exit 0
fi
if ! go build -o "$work/gen" ./scripts/generate_green_verification_report 2>"$work/build.err"; then
  echo "FAIL  ビルドできない: $(cat "$work/build.err")"; exit 1
fi

base=(
  --template "$T"
  --green-instance "$C/green-db-instance.json"
  --deployment "$C/deployment.json"
  --user-parameters "$C/green-user-parameters.json"
  --system-parameters "$C/green-system-parameters.json"
  --all-parameters "$C/green-all-parameters.json"
  --replica-lag "$C/replica-lag.json"
)
# fixture の実状態に一致する宣言値。
expect_ok=(
  --expect-engine-version 8.4.10
  --expect-instance-class db.t4g.medium
  --expect-parameter-group example-production-mysql84-v1
)

# --- ① --output だけ（従来の使い方）---------------------------------------
"$work/gen" "${base[@]}" --output "$work/report-only.md" 2>"$work/e1"; status=$?
check_status '--output だけ: 成功する' 0 "$status"
if grep -q '検証結果' "$work/report-only.md"; then
  echo 'FAIL  --check なしで検証節が出ている'; failed=$((failed + 1))
else
  echo 'ok    --output だけ: 検証節は出ない（従来どおり）'
fi

# --- ② --check だけ（レポートを書かない）-----------------------------------
"$work/gen" "${base[@]}" --check "${expect_ok[@]}" >"$work/o2" 2>"$work/e2"; status=$?
check_status '--check だけ: 適合なら成功' 0 "$status"
if [[ -e "$work/none.md" ]]; then
  echo 'FAIL  --output 未指定なのにレポートを書いた'; failed=$((failed + 1))
else
  echo 'ok    --check だけ: レポートを書かない'
fi

# --- ③ 両方 ---------------------------------------------------------------
"$work/gen" "${base[@]}" --check "${expect_ok[@]}" --output "$work/both.md" 2>"$work/e3"; status=$?
check_status '--check と --output の併用: 成功する' 0 "$status"
both=$(cat "$work/both.md")
check '併用: 検証節が出る' '## 0. 検証結果' "$both"
check '併用: 全件適合と出る' '**すべて適合**（5 件）' "$both"
check '併用: エンジンを検査する' 'Green のエンジンバージョン' "$both"
check '併用: 適用状態を検査する' 'パラメータグループの適用状態' "$both"
check '併用: レプリカ遅延を検査する' 'レプリカ遅延' "$both"

# --- ④ どちらも指定しない --------------------------------------------------
"$work/gen" "${base[@]}" >"$work/o4" 2>"$work/e4"; status=$?
check_status 'どちらも無し: 使い方の誤りとして 2' 2 "$status"
check 'どちらも無し: 理由を出す' '--output か --check の少なくとも一方' "$(cat "$work/e4")"

# --- ⑤ 不適合の検出（1 項目ずつ崩す）---------------------------------------
run_mismatch() {
  local desc=$1 expected_message=$2; shift 2
  "$work/gen" "${base[@]}" --check "$@" --output "$work/ng.md" 2>"$work/ng.err"
  local status=$?
  if [[ "$status" -ne 1 ]]; then
    printf 'FAIL  %-54s 期待 exit=1 実際 exit=%s\n' "$desc" "$status"; failed=$((failed + 1)); return
  fi
  check "$desc" "$expected_message" "$(cat "$work/ng.err")"
  check "${desc}（レポートにも出る）" '**不適合**' "$(cat "$work/ng.md")"
}
run_mismatch 'エンジンバージョン不一致を検出' 'Green のエンジンバージョン' \
  --expect-engine-version 8.0.39 --expect-instance-class db.t4g.medium \
  --expect-parameter-group example-production-mysql84-v1
run_mismatch 'インスタンスクラス不一致を検出' 'Green のインスタンスクラス' \
  --expect-engine-version 8.4.10 --expect-instance-class db.r6g.2xlarge \
  --expect-parameter-group example-production-mysql84-v1
run_mismatch 'パラメータグループ未関連付けを検出' '関連付けなし' \
  --expect-engine-version 8.4.10 --expect-instance-class db.t4g.medium \
  --expect-parameter-group not-associated-pg

# --- ⑥ レプリカ遅延 --------------------------------------------------------
printf '{"Datapoints":[]}\n' > "$work/lag-empty.json"
"$work/gen" --template "$T" --green-instance "$C/green-db-instance.json" \
  --deployment "$C/deployment.json" --user-parameters "$C/green-user-parameters.json" \
  --system-parameters "$C/green-system-parameters.json" --all-parameters "$C/green-all-parameters.json" \
  --replica-lag "$work/lag-empty.json" --check "${expect_ok[@]}" 2>"$work/lag.err"; status=$?
check_status 'データポイントなしを不適合にする' 1 "$status"
check 'データポイントなし: 理由を出す' 'データポイントなし' "$(cat "$work/lag.err")"

printf '{"Datapoints":[{"Maximum":12.5}]}\n' > "$work/lag-nonzero.json"
"$work/gen" --template "$T" --green-instance "$C/green-db-instance.json" \
  --deployment "$C/deployment.json" --user-parameters "$C/green-user-parameters.json" \
  --system-parameters "$C/green-system-parameters.json" --all-parameters "$C/green-all-parameters.json" \
  --replica-lag "$work/lag-nonzero.json" --check "${expect_ok[@]}" 2>"$work/lag2.err"; status=$?
check_status '遅延が残っていれば不適合' 1 "$status"
check '遅延あり: 実測値を出す' '12.500 秒' "$(cat "$work/lag2.err")"

echo
if [[ "$failed" -eq 0 ]]; then echo 'すべて期待どおり。'; exit 0; fi
echo "不適合: ${failed} 件" >&2; exit 1
