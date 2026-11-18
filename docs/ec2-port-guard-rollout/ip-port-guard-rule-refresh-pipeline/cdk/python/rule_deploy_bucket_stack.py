"""ルールのデプロイ先バケットのスタック。作り方の記録として残す。

YAML 版 cloudformation/rule-deploy-bucket.yml と同じ定義（tests/test_stack.py で照合する）。
このアカウントでは 2026-11-17 に手で作成済みなので、このスタックは流さない。
別のアカウント・リージョンで作るとき、または作り直すときに使う。パイプライン用スタックとは独立していて、
ローカル・踏み台サーバーのコマンドからも、パイプラインからも、このバケットを名前で参照する。
"""

import aws_cdk as cdk
from aws_cdk import aws_s3 as s3
from constructs import Construct


class RuleDeployBucketStack(cdk.Stack):
    def __init__(self, scope: Construct, stack_name: str) -> None:
        super().__init__(scope, stack_name, stack_name=stack_name,
                         synthesizer=cdk.BootstraplessSynthesizer(), analytics_reporting=False)
        # パイプライン用スタックの RuleDeployBucketNamePrefix と、ローカルの入口スクリプトが組み立てる名前に合わせる
        prefix = cdk.CfnParameter(self, "RuleDeployBucketNamePrefix", type="String", default="ip-port-guard-rules")

        # 実際の名前は <先頭部分>-<アカウント ID>-<リージョン>-an。
        # 上書き前のルールを残す（古い版は消さない）。パブリックアクセスはすべてブロックし、権限で読み書きする。
        # デプロイ済みのルールを失わないよう、スタックを削除・置き換えしてもバケットは残す。
        bucket = s3.Bucket(
            self, "RuleDeployBucket",
            bucket_name_prefix=prefix.value_as_string,
            bucket_namespace=s3.BucketNamespace.ACCOUNT_REGIONAL,
            versioned=True,
            encryption=s3.BucketEncryption.S3_MANAGED,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            object_ownership=s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )
        bucket.node.default_child.override_logical_id("RuleDeployBucket")  # YAML 版と同じ論理 ID にする
        cdk.CfnOutput(self, "RuleDeployBucketName", value=bucket.bucket_name)
