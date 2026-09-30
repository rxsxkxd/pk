#!/bin/bash
# このファイルは cmd/generate-definitions が config/ami_publish.yml から生成した。手で編集しない。
# 環境 staging の仕組み（3 つのスタック）をデプロイ・削除する。ami-publish/ のルートで実行する。
#
#   bash generated/deploy/staging.sh up    依存関係の順に変更セットを作る（反映はしない）
#   bash generated/deploy/staging.sh down  依存関係の逆順にスタックを削除する
#
# up の後は、表示される変更セットを確認してから、依存関係の順に反映する:
#   aws cloudformation describe-change-set --stack-name <スタック名> --change-set-name <変更セット名>
#   aws cloudformation execute-change-set  --stack-name <スタック名> --change-set-name <変更セット名>
# 初回は、1・2 を反映してから、もう一度 up を実行する（3 は 1・2 の Export を参照するため、
# 1・2 が反映されるまで 3 の変更セットは作れず、エラーで止まる。反映済みの 1・2 は「変更なし」で通過する）。
# down はスタックのリソースを削除する。AMI とスナップショットはスタックのリソースではないため残る。
# 参照されている Export があるスタックは削除できないため、down は参照する側（3）から順に削除する。
set -eu

up() {
  # 1. ヘルスチェック（SSM ドキュメント）
  aws cloudformation deploy --region ap-northeast-1 --stack-name myapp-staging-health-check \
    --template-file generated/cloudformation/staging/health-check-stack.yml \
    --capabilities CAPABILITY_IAM --no-execute-changeset --no-fail-on-empty-changeset
  # 2. 起動テンプレート（AmiId / AppVersion は指定しない。初回は空で作られ、以降は現在の値を引き継ぐ）
  aws cloudformation deploy --region ap-northeast-1 --stack-name myapp-staging-launch-template \
    --template-file generated/cloudformation/staging/launch-template-stack.yml \
    --capabilities CAPABILITY_IAM --no-execute-changeset --no-fail-on-empty-changeset
  # 3. AMI 公開パイプライン
  aws cloudformation deploy --region ap-northeast-1 --stack-name myapp-staging-ami-publish-pipeline \
    --template-file generated/cloudformation/staging/ami-publish-pipeline-stack.yml \
    --capabilities CAPABILITY_IAM --no-execute-changeset --no-fail-on-empty-changeset
}

down() {
  # 1. AMI 公開パイプライン
  # アーティファクト用の S3 バケットは、中身が残っているとスタックを削除できないため先に空にする
  bucket=$(aws cloudformation describe-stacks --region ap-northeast-1 --stack-name myapp-staging-ami-publish-pipeline \
    --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" --output text)
  aws s3 rm --region ap-northeast-1 "s3://${bucket}" --recursive
  aws cloudformation delete-stack --region ap-northeast-1 --stack-name myapp-staging-ami-publish-pipeline
  aws cloudformation wait stack-delete-complete --region ap-northeast-1 --stack-name myapp-staging-ami-publish-pipeline
  # 2. 起動テンプレート
  aws cloudformation delete-stack --region ap-northeast-1 --stack-name myapp-staging-launch-template
  aws cloudformation wait stack-delete-complete --region ap-northeast-1 --stack-name myapp-staging-launch-template
  # 3. ヘルスチェック（SSM ドキュメント）
  aws cloudformation delete-stack --region ap-northeast-1 --stack-name myapp-staging-health-check
  aws cloudformation wait stack-delete-complete --region ap-northeast-1 --stack-name myapp-staging-health-check
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "使い方: bash generated/deploy/staging.sh up|down" >&2; exit 2 ;;
esac
