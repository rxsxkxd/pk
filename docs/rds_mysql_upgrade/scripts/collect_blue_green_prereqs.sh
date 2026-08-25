#!/usr/bin/env bash
# AWS CLI の読み取り API だけを使い、Blue/Green の事前確認情報を収集する。
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: collect_blue_green_prereqs.sh --db-instance-id ID [options]
  --region REGION             AWS Region (default: AWS CLI configuration)
  --profile PROFILE           AWS CLI profile (default: AWS CLI configuration)
  --target-engine-version V   Target MySQL version (default: 8.4.9)
  --output-dir DIR            Directory for collected JSON (default: temporary directory)
USAGE
}

db_instance_id=''; region=''; profile=''; target_engine_version='8.4.9'; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-instance-id) db_instance_id=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --target-engine-version) target_engine_version=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$db_instance_id" ]] || { echo '--db-instance-id is required.' >&2; exit 2; }

[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-prereqs.XXXXXX")
mkdir -p "$output_dir"
aws_args=()
[[ -n "$region" ]] && aws_args+=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# 以下はすべて AWS の読み取り API（Describe*/Get*）であり、設定を変更しない。
# [0-1-01][0-1-05][0-1-07][0-1-08][0-1-10][0-1-12][0-1-14]
# 対象 Blue のバックアップ保持期間、DB クラス、適用中のパラメータ／オプション
# グループ、上流／配下リードレプリカ、Secrets Manager・IAM DB 認証の利用状態を取得する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$db_instance_id" --output json > "$output_dir/db-instance.json"

# [0-1-06] 外部 binlog レプリカは AWS CLI の読み取り API だけでは判定できない。
# Ruby の判定結果では手動確認として出力し、`SHOW REPLICA STATUS\G` の結果を別途確認する。

# 同一リージョンの全 DB インスタンスのレプリカ親子関係を取得する。
# [0-1-07] 対象 Blue の直接配下レプリカにさらに配下がある、カスケード構成を Ruby で判定するために使う。
aws "${aws_args[@]}" rds describe-db-instances --output json > "$output_dir/all-db-instances.json"

parameter_group=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("DBInstances").first.fetch("DBParameterGroups").first.fetch("DBParameterGroupName")' "$output_dir/db-instance.json")
option_group=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("DBInstances").first.fetch("OptionGroupMemberships").first.fetch("OptionGroupName")' "$output_dir/db-instance.json")

# [0-1-02] 対象 Blue に適用中のパラメータグループの全パラメータを取得する。
# binlog_format の現行値を記録する。RDS for MySQL の Blue/Green 作成では ROW は必須ではないため、運用方針として Ruby で報告する。
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$parameter_group" --output json > "$output_dir/db-parameters.json"

# [0-1-03][0-1-04] 適用中オプショングループの全オプションを取得する。
# デフォルトグループかどうかと、MEMCACHED オプションの有無を Ruby で判定する。
aws "${aws_args[@]}" rds describe-option-groups --option-group-name "$option_group" --output json > "$output_dir/option-group.json"

# [0-1-08] 指定した 8.4 のエンジンバージョンで作成可能な DB クラス一覧を取得する。
# 現行 Blue の DB クラスが移行先バージョンに対して選択可能かを Ruby で判定する。
aws "${aws_args[@]}" rds describe-orderable-db-instance-options --engine mysql --engine-version "$target_engine_version" --output json > "$output_dir/orderable-classes.json"

# [0-1-13] リージョン内の RDS Proxy 一覧を取得する。
# Proxy が存在する環境では、対象 Blue が切替前から登録済みかを追加確認する必要があるため、レビュー対象として報告する。
aws "${aws_args[@]}" rds describe-db-proxies --output json > "$output_dir/db-proxies.json"

# [0-1-13] 各 Proxy の登録ターゲットを取得する。対象 Blue の DbiResourceId が登録済みかを Ruby で判定する。
proxy_index=0
while IFS= read -r proxy_name; do
  [[ -n "$proxy_name" ]] || continue
  aws "${aws_args[@]}" rds describe-db-proxy-targets --db-proxy-name "$proxy_name" --output json > "$output_dir/db-proxy-targets-${proxy_index}.json"
  proxy_index=$((proxy_index + 1))
done < <(ruby -rjson -e 'JSON.parse(File.read(ARGV[0])).fetch("DBProxies", []).each { |proxy| puts proxy["DBProxyName"] }' "$output_dir/db-proxies.json")

# [0-1-11] リージョン内の RDS Integration（Zero-ETL 統合を含む）を取得する。
# 対象 DB ARN が source／target に含まれる統合を Ruby で抽出し、制約確認が必要な状態として報告する。
aws "${aws_args[@]}" rds describe-integrations --output json > "$output_dir/integrations.json"

start_time=$(ruby -rtime -e 'puts (Time.now.utc - 3600).iso8601')
end_time=$(ruby -rtime -e 'puts Time.now.utc.iso8601')
# [0-1-09] 対象 Blue の CloudWatch メトリクス FreeStorageSpace の直近 1 時間における最小値を取得する。
# Ruby で 2 GiB を目安に空きストレージ余裕を判定する。値の単位は Byte。
aws "${aws_args[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace --dimensions "Name=DBInstanceIdentifier,Value=$db_instance_id" --statistics Minimum --period 300 --start-time "$start_time" --end-time "$end_time" --output json > "$output_dir/free-storage-space.json"

printf '{"db_instance_id":"%s","target_engine_version":"%s","collected_at":"%s"}\n' "$db_instance_id" "$target_engine_version" "$end_time" > "$output_dir/metadata.json"
echo "Collected read-only AWS CLI results: $output_dir"
echo "Evaluate: ruby scripts/evaluate_blue_green_prereqs.rb --input-dir $output_dir"
