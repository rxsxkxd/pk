#!/bin/bash
# 生成スクリプトの取得スクリプト。一覧更新パイプラインの CodeBuild の中で流す（このファイルだけを圧縮したものが、パイプラインのソース）
# パイプライン用バケットの generator-scripts/command/ から、生成スクリプト 3 つ（make-jp-lists.sh・make-aws-lists.sh・make-refresh.sh）を
# command/ に取る。取った版（S3 の VersionId）と SHA-256 を、使った生成スクリプトの版の記録 generator-scripts-versions.txt に書く
# 取得先は CodeBuild の環境変数 GENERATOR_SCRIPTS_BUCKET・GENERATOR_SCRIPTS_PREFIX で渡す
set -euo pipefail
: "${GENERATOR_SCRIPTS_BUCKET:?GENERATOR_SCRIPTS_BUCKET がない}"
: "${GENERATOR_SCRIPTS_PREFIX:?GENERATOR_SCRIPTS_PREFIX がない}"

mkdir -p command
{
  echo "# 使った生成スクリプトの版（取得元 s3://${GENERATOR_SCRIPTS_BUCKET}/${GENERATOR_SCRIPTS_PREFIX}/）"
  printf '# file\ts3_version_id\tsha256\n'
} > generator-scripts-versions.txt

for name in make-jp-lists.sh make-aws-lists.sh make-refresh.sh; do
  key="${GENERATOR_SCRIPTS_PREFIX}/command/${name}"
  # 今の版を決めてから、その版を取る（取っている途中で上書きされても、記録と中身がずれない）
  version=$(aws s3api head-object --bucket "$GENERATOR_SCRIPTS_BUCKET" --key "$key" --query VersionId --output text)
  aws s3api get-object --bucket "$GENERATOR_SCRIPTS_BUCKET" --key "$key" --version-id "$version" "command/${name}" > /dev/null
  printf '%s\t%s\t%s\n' "command/${name}" "$version" "$(sha256sum "command/${name}" | cut -d' ' -f1)" >> generator-scripts-versions.txt
done

cat generator-scripts-versions.txt
