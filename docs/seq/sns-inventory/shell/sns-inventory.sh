#!/usr/bin/env bash
# SNS トピックの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=sns-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='attributes:sns_topic tags:sns_topic'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  aws_json sns list-topics >"$work/topics.json"
  # サブスクリプションはリージョン全体を 1 回で引き、トピック ARN で突き合わせる
  aws_json sns list-subscriptions >"$work/subscriptions.json"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile topics "$work/topics.json" \
    --slurpfile subscriptions "$work/subscriptions.json" "$jq_lib"'
    $subscriptions[0].Subscriptions as $subs
    | $topics[0].Topics[]
    | .TopicArn as $arn
    | [$subs[] | select(.TopicArn == $arn)] as $own
    | record("sns_topic"; {
        topic_arn: $arn,
        topic_name: ($arn | split(":")[-1]),
        fifo: ($arn | endswith(".fifo")),
        subscription_count: ($own | length),
        subscriptions: [
          $own[]
          # メールアドレスと電話番号は個人の情報なので出さない
          | {subscription_arn: .SubscriptionArn, protocol: .Protocol,
             endpoint: (if (.Protocol | IN("email", "email-json", "sms")) then null else .Endpoint end),
             pending_confirmation: (.SubscriptionArn == "PendingConfirmation")}
        ]
      })'
}

# 暗号化・配信の状況・アクセスポリシーの要約
detail_attributes() {
  local arn
  arn=$(jq -r '.topic_arn' <<<"$1")
  aws_paced sns get-topic-attributes --topic-arn "$arn" | jq -c '
    .Attributes as $a
    | ($a.Policy // "{}" | fromjson | .Statement // []) as $statements
    | {
        display_name: $a.DisplayName,
        kms_master_key_id: $a.KmsMasterKeyId,
        subscriptions_confirmed: ($a.SubscriptionsConfirmed | if . == null then null else tonumber end),
        subscriptions_pending: ($a.SubscriptionsPending | if . == null then null else tonumber end),
        content_based_deduplication: ($a.ContentBasedDeduplication | if . == null then null else . == "true" end),
        tracing_config: $a.TracingConfig,
        signature_version: $a.SignatureVersion,
        policy_statement_count: ($statements | length),
        # 条件なしで、だれにでも（Principal が * ）許可している文の数
        policy_public_statement_count: (
          [$statements[] | select(.Effect == "Allow" and .Condition == null
             and ([.Principal | if type == "object" then .AWS else . end] | flatten | index("*") != null))] | length
        )
      }'
}

detail_tags() {
  local arn
  arn=$(jq -r '.topic_arn' <<<"$1")
  aws_paced sns list-tags-for-resource --resource-arn "$arn" | jq -c "$jq_lib"'.Tags | tags_object'
}

run_main "$@"
