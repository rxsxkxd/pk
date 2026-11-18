"""CDK のスタックを合成する。アセット・AWS 接続・ブートストラップは使わない。

- パイプライン用スタック（環境ごと）: 既定の名前は port-guard-list-refresh-staging。-c stackName=... で変え、
  ルールジェネレーターのリポジトリのホストを -c sourceProvider=GitHub|CodeCommit で選ぶ（既定は GitHub）
- ルールのデプロイ先バケットのスタック: 作り方の記録。このアカウントでは流さない（手で作成済み）。
  既定の名前は port-guard-rule-deploy-bucket。-c ruleDeployBucketStackName=... で変える
2 つのスタックの間に依存はない。
"""

import aws_cdk as cdk

from list_refresh_stack import ListRefreshPipelineStack
from rule_deploy_bucket_stack import RuleDeployBucketStack

app = cdk.App()
context = app.node.try_get_context
ListRefreshPipelineStack(app, context("stackName") or "port-guard-list-refresh-staging",
                         context("sourceProvider") or "GitHub")
RuleDeployBucketStack(app, context("ruleDeployBucketStackName") or "port-guard-rule-deploy-bucket")
app.synth()
