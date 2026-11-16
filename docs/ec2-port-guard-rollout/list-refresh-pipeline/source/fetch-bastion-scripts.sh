#!/bin/bash
# 踏み台サーバーの手順のスクリプトの取得スクリプト。一覧更新パイプラインの CodeBuild（一覧を作るビルド）の中で流す
# （このファイルだけを圧縮した fetch-bastion-scripts.zip が、パイプラインのソース）
# パイプライン用バケットの bastion-scripts/command/ から、踏み台サーバーの手順のスクリプト 5 つを command/ に取る。
# 取った版（S3 の VersionId）と SHA-256 を、使った踏み台サーバーの手順のスクリプトの版の記録 bastion-scripts-versions.txt に書く
# 取得先は CodeBuild の環境変数 BASTION_SCRIPTS_BUCKET・BASTION_SCRIPTS_PREFIX で渡す
set -euo pipefail
: "${BASTION_SCRIPTS_BUCKET:?BASTION_SCRIPTS_BUCKET がない}"
: "${BASTION_SCRIPTS_PREFIX:?BASTION_SCRIPTS_PREFIX がない}"

mkdir -p command
{
  echo "# 使った踏み台サーバーの手順のスクリプトの版（取得元 s3://${BASTION_SCRIPTS_BUCKET}/${BASTION_SCRIPTS_PREFIX}/）"
  printf '# file\ts3_version_id\tsha256\n'
} > bastion-scripts-versions.txt

for name in fetch-allow-and-last-lists.sh make-jp-lists.sh make-aws-lists.sh make-refresh.sh publish-refresh-scripts.sh; do
  key="${BASTION_SCRIPTS_PREFIX}/command/${name}"
  # 今の版を決めてから、その版を取る（取っている途中で上書きされても、記録と中身がずれない）
  version=$(aws s3api head-object --bucket "$BASTION_SCRIPTS_BUCKET" --key "$key" --query VersionId --output text)
  aws s3api get-object --bucket "$BASTION_SCRIPTS_BUCKET" --key "$key" --version-id "$version" "command/${name}" > /dev/null
  printf '%s\t%s\t%s\n' "command/${name}" "$version" "$(sha256sum "command/${name}" | cut -d' ' -f1)" >> bastion-scripts-versions.txt
done

cat bastion-scripts-versions.txt
