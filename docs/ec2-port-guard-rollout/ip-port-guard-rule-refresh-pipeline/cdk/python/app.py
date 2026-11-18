"""パイプライン用スタックを合成する。アセット・AWS 接続・ブートストラップは使わない。"""  # このアプリで合成するスタックの範囲を示す。

import aws_cdk as cdk  # CDK アプリの作成と、実行時のコンテキスト取得に使う。
from list_refresh_stack import ListRefreshPipelineStack  # パイプライン用スタックの定義を読み込む。

app = cdk.App()  # スタックをまとめる CDK アプリを作る。
ListRefreshPipelineStack(app, app.node.try_get_context("stackName") or "port-guard-list-refresh-staging",  # パイプライン用スタックを作り、必要ならコンテキストで名前を変える。
                         app.node.try_get_context("sourceProvider") or "GitHub")  # ルールジェネレーターのリポジトリのホストを、合成時のコンテキストで選ぶ（既定は GitHub）。
app.synth()  # 定義から CloudFormation テンプレートをローカルで合成する。
