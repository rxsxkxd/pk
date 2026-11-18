#!/bin/bash
# CI（CodePipeline の Make のビルド）だけで使う。build-rules.sh が失敗したときに、その表示（止まった理由と、一覧ごとの件数・増減）を
# SNS のトピックへ送る。手動（ローカル・踏み台サーバー）では使わない
# 使い方: bash command/notify-make-failure.sh <build-rules.sh の表示を残したファイル>
# 環境変数: NOTIFICATION_TOPIC_ARN（空なら何もしない）・ENVIRONMENT_NAME（パイプライン用スタックが渡す）
set -euo pipefail
LOG=${1:?build-rules.sh の表示を残したファイルを指定する}
[ -n "${NOTIFICATION_TOPIC_ARN:-}" ] || exit 0
pipeline="port-guard-list-refresh-${ENVIRONMENT_NAME}"

# 増減の確認（make-refresh.sh）で止まったときは「〜一覧があるので止める」が出る
if grep -q '一覧があるので止める' "$LOG" 2>/dev/null; then
  subject="[port-guard] ${ENVIRONMENT_NAME}: 増減の確認でルールの作成が止まった"
  # 一覧ごとの件数・増減と、止まった理由
  summary=$(grep -E '^(jp|aws|allow)-ipv[46]: |一覧があるので止める' "$LOG")
else
  subject="[port-guard] ${ENVIRONMENT_NAME}: ルールの作成のビルドが失敗した"
  # 増減の確認より前で失敗した（公開元の取得など）。最後の表示を載せる
  summary=$(tail -n 20 "$LOG" 2>/dev/null || echo "（表示が残っていない）")
fi

message="パイプライン ${pipeline} の Make のビルドが失敗した。ルールのデプロイ先には何も上げていない（各サーバーのルールは前のまま）。

${summary}

ビルドのログ: ${CODEBUILD_BUILD_URL:-CloudWatch Logs の /aws/codebuild/port-guard-list-refresh-${ENVIRONMENT_NAME}（ストリーム make/...）}

次にすること（ip-port-guard-rule-refresh-pipeline/design-decisions.md の「ルールを作るときに問題が起きたときの扱い」）:
- 下限の確認で止まったとき: 一覧そのものがおかしい。原因を直す（FORCE=1 では通せない）
- 5% の確認で止まったとき: 手元で build-rules.sh ${ENVIRONMENT_NAME} を流して差分を確かめ、問題なければ次で開始する
  aws codepipeline start-pipeline-execution --name ${pipeline} --variables name=FORCE,value=1"

aws sns publish --topic-arn "$NOTIFICATION_TOPIC_ARN" --subject "$subject" --message "$message" > /dev/null
echo "SNS のトピックへ送った: ${subject}"
