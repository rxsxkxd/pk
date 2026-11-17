"""2 スタックを合成する。アセット・AWS 接続・ブートストラップは使わない。"""  # このアプリで合成する2スタックの範囲を示す。

import aws_cdk as cdk  # CDK アプリの作成と、実行時のコンテキスト取得に使う。
from list_refresh_stack import ListRefreshPipelineStack  # パイプライン用スタックの定義を読み込む。
from rule_buckets_stack import RuleBucketsStack  # バケット用スタックの定義を読み込む。

app = cdk.App()  # 2つのスタックをまとめる CDK アプリを作る。
buckets = RuleBucketsStack(app, app.node.try_get_context("bucketStackName") or "port-guard-rule-buckets")  # バケット用スタックを作り、必要ならコンテキストで名前を変える。
flow = ListRefreshPipelineStack(app, app.node.try_get_context("stackName") or "port-guard-list-refresh-staging")  # パイプライン用スタックを作り、必要ならコンテキストで名前を変える。
flow.add_stack_dependency(buckets)  # 両方をデプロイする場合はバケット用を先にする。バケット名はパラメータで渡す。
app.synth()  # 定義から2つの CloudFormation テンプレートをローカルで合成する。
