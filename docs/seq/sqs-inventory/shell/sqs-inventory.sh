#!/usr/bin/env bash
# SQS キューの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=sqs-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='attributes:sqs_queue tags:sqs_queue'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  # キューが 1 つも無いと、CLI は何も出さない
  aws_json sqs list-queues | jq -c --argjson common "$common" "$jq_lib"'
    .QueueUrls[]?
    | record("sqs_queue"; {
        queue_url: .,
        queue_name: split("/")[-1],
        fifo: endswith(".fifo")
      })'
}

# キューの設定・溜まっているメッセージ数・デッドレターキュー・暗号化・アクセスポリシーの要約
detail_attributes() {
  local url
  url=$(jq -r '.queue_url' <<<"$1")
  aws_paced sqs get-queue-attributes --queue-url "$url" --attribute-names All | jq -c "$jq_lib"'
    def int: if . == null then null else tonumber end;
    def bool: if . == null then null else . == "true" end;
    .Attributes as $a
    | ($a.RedrivePolicy // "{}" | fromjson) as $redrive
    | ($a.Policy // "{}" | fromjson | .Statement // []) as $statements
    | {
        queue_arn: $a.QueueArn,
        visibility_timeout_sec: ($a.VisibilityTimeout | int),
        message_retention_sec: ($a.MessageRetentionPeriod | int),
        maximum_message_size: ($a.MaximumMessageSize | int),
        delay_sec: ($a.DelaySeconds | int),
        receive_wait_time_sec: ($a.ReceiveMessageWaitTimeSeconds | int),
        approximate_messages: ($a.ApproximateNumberOfMessages | int),
        approximate_messages_not_visible: ($a.ApproximateNumberOfMessagesNotVisible | int),
        approximate_messages_delayed: ($a.ApproximateNumberOfMessagesDelayed | int),
        dead_letter_target_arn: $redrive.deadLetterTargetArn,
        max_receive_count: $redrive.maxReceiveCount,
        kms_master_key_id: $a.KmsMasterKeyId,
        sqs_managed_sse_enabled: ($a.SqsManagedSseEnabled | bool),
        content_based_deduplication: ($a.ContentBasedDeduplication | bool),
        created_at: ($a.CreatedTimestamp | epoch_iso),
        last_modified_at: ($a.LastModifiedTimestamp | epoch_iso),
        policy_statement_count: ($statements | length),
        # 条件なしで、だれにでも（Principal が * ）許可している文の数
        policy_public_statement_count: (
          [$statements[] | select(.Effect == "Allow" and .Condition == null
             and ([.Principal | if type == "object" then .AWS else . end] | flatten | index("*") != null))] | length
        )
      }'
}

detail_tags() {
  local url
  url=$(jq -r '.queue_url' <<<"$1")
  aws_paced sqs list-queue-tags --queue-url "$url" | jq -c '.Tags // {}'
}

run_main "$@"
