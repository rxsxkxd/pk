"""一覧更新パイプラインの CDK（Python）版。合成は AWS に接続しない。"""

import aws_cdk as cdk

from list_refresh_stack import ListRefreshPipelineStack


def main() -> None:
    app = cdk.App()
    # 環境名などのリソースの設定は、CloudFormation 版と同じデプロイ時のパラメータで渡す。
    stack_name = app.node.try_get_context("stackName") or "port-guard-list-refresh-staging"
    ListRefreshPipelineStack(app, stack_name)
    app.synth()


if __name__ == "__main__":
    main()
