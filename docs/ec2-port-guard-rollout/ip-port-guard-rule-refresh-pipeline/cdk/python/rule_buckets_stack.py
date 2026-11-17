"""バケット用スタック。既存のルール用バケットは既定では作成・変更しない。"""  # バケット用スタックの役割を示す。

import aws_cdk as cdk  # スタック・パラメータ・条件などの CDK 共通機能を使う。
from aws_cdk import aws_s3 as s3  # S3 バケットを L2 の構成要素で定義する。
from constructs import Construct  # CDK の構成要素の親を表す型を使う。


class RuleBucketsStack(cdk.Stack):  # 環境間で共用するバケット用スタックを定義する。
    def __init__(self, scope: Construct, stack_name: str) -> None:  # 親の構成要素とスタック名を受け取る。
        super().__init__(scope, stack_name, stack_name=stack_name,  # CloudFormation のスタックを指定した名前で初期化する。
                         synthesizer=cdk.BootstraplessSynthesizer(), analytics_reporting=False)  # アセット用バケットと bootstrap を不要にし、利用状況メタデータを付けない。
        artifact_prefix = cdk.CfnParameter(self, "PipelineBucketNamePrefix", type="String",  # 中間成果物用バケット名の先頭部分をパラメータで受け取る。
                                          default="ip-port-guard-pipeline")  # 省略したときの先頭部分を ip-port-guard-pipeline にする。
        create = cdk.CfnParameter(self, "CreatePublishBucket", type="String", default="false",  # ルール用バケットの新規作成は既定で無効にする。
                                  allowed_values=["true", "false"])  # 作成するかの指定は文字列の true または false に限定する。
        existing = cdk.CfnParameter(self, "PublishBucketName", type="String", default="")  # 既存バケットを別名で使う場合の完全名を受け取る。
        create_rule = cdk.CfnCondition(self, "CreateRuleBucket",  # ルール用バケットを新規作成するための条件を作る。
                                      expression=cdk.Fn.condition_equals(create.value_as_string, "true"))  # CreatePublishBucket が true のときだけ作成する。
        create_rule.override_logical_id("CreatePublishBucket")  # YAML 版と同じ CloudFormation 条件名で出力する。
        default_rule = cdk.CfnCondition(self, "UseDefaultPublishBucket",  # 既存バケット名を自動で決めるかの条件を作る。
                                       expression=cdk.Fn.condition_equals(existing.value_as_string, ""))  # 既存バケット名の指定が空なら、規定の接尾辞付きの名前を使う。

        def bucket(name, prefix, **extra):  # 2つのバケットに共通する設定をまとめる。
            return s3.Bucket(  # S3 バケットを L2 で定義する。
                self, name, bucket_name_prefix=prefix,  # 構成要素の名前と、バケット名の先頭部分を指定する。
                bucket_namespace=s3.BucketNamespace.ACCOUNT_REGIONAL,  # アカウントとリージョンの接尾辞を持つ名前空間を使う。
                versioned=True, encryption=s3.BucketEncryption.S3_MANAGED,  # バージョニングを有効にし、SSE-S3 で暗号化する。
                block_public_access=s3.BlockPublicAccess.BLOCK_ALL,  # 4種類のパブリックアクセスのブロックをすべて有効にする。
                object_ownership=s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,  # 所有者をバケット所有者に統一し、ACL を無効にする。
                removal_policy=cdk.RemovalPolicy.RETAIN, **extra,  # 削除・置き換え時にもバケットを保持し、個別の追加設定も受け取る。
            )  # 定義したバケットを呼び出し側へ返す。

        artifacts = bucket("PipelineBucket", artifact_prefix.value_as_string, lifecycle_rules=[s3.LifecycleRule(  # 中間成果物用バケットと、その世代管理ルールを作る。
            id="expire-noncurrent-versions", noncurrent_version_expiration=cdk.Duration.days(90))])  # 現在の版を残し、現行ではなくなった版を90日で削除する。
        rules = bucket("PublishBucket", "ip-port-guard-rules")  # 必要な場合にだけ使う、新規ルール用バケットの定義を用意する。
        rules.node.default_child.cfn_options.condition = create_rule  # 新規作成の条件を L1 リソースに付け、既定では作成しない。
        rule_name = cdk.Fn.condition_if(create_rule.logical_id, rules.bucket_name,  # 新規作成時はそのバケット名を、スタックの出力用に選ぶ。
                                       cdk.Fn.condition_if(default_rule.logical_id,  # 既存バケットを使うときは、既定名か指定名かをさらに選ぶ。
                                           cdk.Fn.sub("ip-port-guard-rules-${AWS::AccountId}-${AWS::Region}-an"),  # 既定名にはデプロイ先のアカウント ID とリージョンを付ける。
                                           existing.value_as_string)).to_string()  # 既存バケットの完全名が指定されたら、その値を使う。
        cdk.CfnOutput(self, "PipelineBucketName", value=artifacts.bucket_name)  # 中間成果物用バケット名を、パイプラインへ渡す出力にする。
        output = cdk.CfnOutput(self, "PublishBucketNameOutput", value=rule_name)  # 選んだルール用バケット名を出力し、パラメータとの名前衝突を避ける。
        output.override_logical_id("PublishBucketName")  # 出力のキーは YAML 版と同じ PublishBucketName にそろえる。
