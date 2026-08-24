#!/usr/bin/env bash
# codepipeline-all-in-one.yml のスタックを、ローカルから登録（up）・削除（down）する。
#
#   examples/rds-blue-green-deployment/pipeline-stack.sh up     # 登録（既にあれば更新）
#   examples/rds-blue-green-deployment/pipeline-stack.sh down   # アーティファクトバケットを空にしてから削除
#
# 値は下の変数を書き換えるか、同じ名前の環境変数で渡す。AWS の認証は通常どおり
# （AWS_PROFILE など）。パイプラインからは呼ばない、人が手で動かすための補助である。
set -euo pipefail

ENVIRONMENT_NAME=${ENVIRONMENT_NAME:-staging}
STACK_NAME=${STACK_NAME:-rds-bg-${ENVIRONMENT_NAME}}
TEMPLATE=$(dirname "$0")/codepipeline-all-in-one.yml

DEFAULT_SERVICE_NAME=${DEFAULT_SERVICE_NAME:-example-service}
CODESTAR_CONNECTION_ARN=${CODESTAR_CONNECTION_ARN:-arn:aws:codeconnections:ap-northeast-1:123456789012:connection/00000000-0000-0000-0000-000000000000}
REPOSITORY_ID=${REPOSITORY_ID:-your-org/your-repository}
BRANCH_NAME=${BRANCH_NAME:-main}
RDS_MONITORING_ROLE_NAME=${RDS_MONITORING_ROLE_NAME:-rds-monitoring-role}
# 変更系の権限を付ける RDS の範囲（カンマ区切りの ARN。ワイルドカード可）。
# 空ならアカウント・リージョン内の db / snapshot 全体が対象になるので、実運用では指定する。
PROTECTED_RDS_RESOURCE_ARNS=${PROTECTED_RDS_RESOURCE_ARNS:-}

case "${1:-}" in
  up)
    extra=()
    [ -n "$PROTECTED_RDS_RESOURCE_ARNS" ] && extra+=("ProtectedRdsResourceArns=${PROTECTED_RDS_RESOURCE_ARNS}")
    # 登録。既にあれば差分だけ更新する（差分が無ければ何もしない）。
    # IAM ロールを名前付きで作るので CAPABILITY_NAMED_IAM が要る。
    # ここに無いパラメータは既定値になる（一覧は ci/codepipeline-all-in-one-parameters.md）。
    aws cloudformation deploy \
      --template-file "$TEMPLATE" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --no-fail-on-empty-changeset \
      --parameter-overrides \
        EnvironmentName="$ENVIRONMENT_NAME" \
        DefaultServiceName="$DEFAULT_SERVICE_NAME" \
        CodeStarConnectionArn="$CODESTAR_CONNECTION_ARN" \
        RepositoryId="$REPOSITORY_ID" \
        BranchName="$BRANCH_NAME" \
        RdsMonitoringRoleName="$RDS_MONITORING_ROLE_NAME" \
        ${extra[@]+"${extra[@]}"}

    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
    ;;

  down)
    # このスタックが作ったアーティファクトバケット（ArtifactBucketName を指定した既存バケットは対象外）。
    bucket=$(aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" \
      --logical-resource-id ArtifactBucket \
      --query 'StackResourceDetail.PhysicalResourceId' --output text 2>/dev/null || true)

    echo "スタック ${STACK_NAME} を削除する。"
    if [ -n "$bucket" ]; then
      echo "アーティファクトバケット ${bucket} も中身ごと削除する（検証レポートなど残したいものは先に取り出す）。"
    else
      echo "アーティファクトバケットはこのスタックの管理外なので触らない。"
    fi
    read -r -p "続けるなら yes と入力: " answer
    [ "$answer" = yes ] || { echo '中止した。'; exit 1; }

    if [ -n "$bucket" ]; then
      # 空でないとスタック削除がバケットを消せずに DELETE_FAILED で止まるので、先に空にする。
      aws s3 rm "s3://${bucket}" --recursive
      # バージョニングを有効にしていた頃に作ったバケットには旧版と削除マーカーが残るので、それも消す。
      for kind in Versions DeleteMarkers; do
        while true; do
          objects=$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 \
            --query "{Objects: ${kind}[].{Key: Key, VersionId: VersionId}}" --output json)
          case "$objects" in *'"Objects": null'*) break ;; esac
          aws s3api delete-objects --bucket "$bucket" --delete "$objects" >/dev/null
        done
      done
    fi

    # スタックを削除する。バケット（DeletionPolicy: Delete）もここで消える。
    aws cloudformation delete-stack --stack-name "$STACK_NAME"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
    echo "削除した: ${STACK_NAME}"
    ;;

  *)
    echo "Usage: $0 up|down" >&2
    exit 2
    ;;
esac
