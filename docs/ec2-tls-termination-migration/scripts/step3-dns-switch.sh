#!/usr/bin/env bash
# ステップ 3: 利用者のドメイン名の A レコードを、Route 53 で CloudFront へ向ける（と、元に戻す）。
#
#   plan      今のレコードを表示し、流す変更バッチを表示する（何も変えない）
#   switch    今のレコード（Elastic IP の A）を控えて、CloudFront を指すエイリアスの A に置き換える
#   rollback  控えたレコードに戻す（エイリアスの A を消し、控えた A を作る）
#
# 置き換えは、DELETE と CREATE を 1 つの変更バッチで流す。Route 53 は変更バッチを全部行うか何も行わないので、
# 途中で名前が引けなくなる時間はない。DELETE は今の値と完全に一致しないと失敗し、そのときは何も変わらない。
# 外部の DNS サービス（本番）には使えない（手順は step3-dns-switch.md の 3-3）。
# 使うもの: AWS CLI v2、jq。手順は ../step3-dns-switch.md。
set -euo pipefail

# CloudFront を指すエイリアスのホストゾーン ID（AWS のドキュメントの AliasTarget で決まっている値）
readonly CLOUDFRONT_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"

usage() {
  cat >&2 <<'EOF'
使い方:
  step3-dns-switch.sh plan     --zone-id <ID> --name <app.example.com> --distribution <dxxxx.cloudfront.net>
  step3-dns-switch.sh switch   --zone-id <ID> --name <app.example.com> --distribution <dxxxx.cloudfront.net> [--backup <ファイル>] [--yes]
  step3-dns-switch.sh rollback --zone-id <ID> --name <app.example.com> [--backup <ファイル>] [--yes]

  --backup  控えのファイル（既定: before-<name>-A.json。switch で書き、rollback で読む）
  --yes     確認の問い合わせをしない
終了コード: 0 = 成功（変更なしを含む） / 1 = 前提が合わない・中止 / 2 = 使い方の誤り
EOF
  exit 2
}

die() { echo "エラー: $*" >&2; exit 1; }

[ $# -ge 1 ] || usage
command="$1"; shift
zone_id=""; name=""; distribution=""; backup=""; assume_yes=false
while [ $# -gt 0 ]; do
  case "$1" in
    --zone-id) zone_id="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    --distribution) distribution="${2:-}"; shift 2 ;;
    --backup) backup="${2:-}"; shift 2 ;;
    --yes) assume_yes=true; shift ;;
    *) usage ;;
  esac
done
case "$command" in plan|switch|rollback) ;; *) usage ;; esac
[ -n "$zone_id" ] && [ -n "$name" ] || usage
if [ "$command" != rollback ] && [ -z "$distribution" ]; then usage; fi

# Route 53 は名前を末尾の「.」付きで返すので、そろえる
fqdn="${name%.}."
[ -n "$distribution" ] && distribution="${distribution%.}."
[ -n "$backup" ] || backup="before-${name%.}-A.json"

command -v aws >/dev/null || die "aws が見つかりません"
command -v jq >/dev/null || die "jq が見つかりません"

# 名前と種類が一致するレコード（0 件か 1 件）を JSON の配列で返す
current_records() {
  local type="$1"
  aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
    --start-record-name "$fqdn" --start-record-type "$type" --max-items 1 --output json \
    | jq --arg n "$fqdn" --arg t "$type" '[.ResourceRecordSets[] | select(.Name == $n and .Type == $t)]'
}

alias_record() {
  jq -n --arg n "$fqdn" --arg z "$CLOUDFRONT_HOSTED_ZONE_ID" --arg d "$1" \
    '{Name: $n, Type: "A", AliasTarget: {HostedZoneId: $z, DNSName: $d, EvaluateTargetHealth: false}}'
}

# DELETE と CREATE を 1 つにまとめた変更バッチ
change_batch() {
  jq -n --arg c "$1" --argjson old "$2" --argjson new "$3" \
    '{Comment: $c, Changes: [{Action: "DELETE", ResourceRecordSet: $old}, {Action: "CREATE", ResourceRecordSet: $new}]}'
}

confirm() {
  $assume_yes && return 0
  printf '%s [y/N] ' "$1" >&2
  local answer=""; read -r answer || true
  [ "$answer" = y ] || [ "$answer" = yes ] || die "中止しました"
}

# [変更] 変更バッチを流し、Route 53 の全サーバーに行き渡る（INSYNC）まで待つ
apply_batch() {
  local batch="$1" change_id
  change_id=$(aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
    --change-batch "$batch" --query 'ChangeInfo.Id' --output text)
  echo "変更を送りました: $change_id。INSYNC になるまで待ちます" >&2
  aws route53 wait resource-record-sets-changed --id "$change_id"
  echo "INSYNC になりました" >&2
}

aaaa=$(current_records AAAA)
[ "$(jq length <<<"$aaaa")" -eq 0 ] \
  || die "$fqdn に AAAA レコードがあります。この道具は A だけを扱うので、先に扱いを決めてください"

a=$(current_records A)
[ "$(jq length <<<"$a")" -eq 1 ] || die "$fqdn の A レコードが 1 件ではありません（$(jq length <<<"$a") 件）"
record=$(jq '.[0]' <<<"$a")
echo "今の A レコード:" >&2
jq . <<<"$record" >&2

case "$command" in
  plan|switch)
    if jq -e --arg d "$distribution" '.AliasTarget.DNSName == $d' <<<"$record" >/dev/null; then
      echo "すでに $distribution を指しています。変えることはありません" >&2
      exit 0
    fi
    jq -e '.AliasTarget == null and (.ResourceRecords | length) > 0 and (.SetIdentifier == null)' <<<"$record" >/dev/null \
      || die "今の A レコードが、値を持つ単純なレコードではありません（エイリアスやルーティングポリシー付き）。手で確かめてください"
    batch=$(change_batch "${fqdn} -> CloudFront ${distribution}" "$record" "$(alias_record "$distribution")")
    echo "流す変更バッチ:" >&2
    jq . <<<"$batch"
    [ "$command" = plan ] && exit 0

    [ ! -e "$backup" ] || die "控えのファイル $backup がすでにあります。前の控えを確かめてから、消すか --backup で別の名前を指定してください"
    jq . <<<"$record" > "$backup"
    echo "今のレコードを $backup に控えました（rollback で使う）" >&2
    confirm "$fqdn を $distribution へ向けますか"
    apply_batch "$batch"
    ;;
  rollback)
    [ -f "$backup" ] || die "控えのファイル $backup がありません"
    old=$(jq . "$backup")
    jq -e --arg n "$fqdn" '.Name == $n and .Type == "A" and .AliasTarget == null' <<<"$old" >/dev/null \
      || die "$backup が $fqdn の値を持つ A レコードの控えではありません"
    jq -e '.AliasTarget.HostedZoneId == "'"$CLOUDFRONT_HOSTED_ZONE_ID"'"' <<<"$record" >/dev/null \
      || die "今の A レコードが CloudFront を指すエイリアスではありません。戻すものがないか、手で変えられています"
    batch=$(change_batch "${fqdn} -> back to $(jq -r '[.ResourceRecords[].Value] | join(",")' <<<"$old")" "$record" "$old")
    echo "流す変更バッチ:" >&2
    jq . <<<"$batch"
    confirm "$fqdn を控えたレコードへ戻しますか"
    apply_batch "$batch"
    ;;
esac

echo "変えた後の A レコード:" >&2
current_records A | jq '.[0]'
