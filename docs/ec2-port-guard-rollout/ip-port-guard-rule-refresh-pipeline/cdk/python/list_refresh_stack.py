"""現行の入口スクリプトを実行するパイプライン。バケットは別スタック。"""  # パイプライン用スタックの役割を示す。

import aws_cdk as cdk  # スタック・パラメータ・条件などの CDK 共通機能を使う。
from aws_cdk import aws_codebuild as build, aws_codepipeline as pipeline  # CodeBuild と CodePipeline を L2 の構成要素で定義する。
from aws_cdk import aws_codepipeline_actions as actions, aws_iam as iam  # パイプラインのアクションと IAM の権限を定義する。
from aws_cdk import aws_logs as logs, aws_s3 as s3  # ログの作成と既存 S3 バケットの参照に使う。
from constructs import Construct  # CDK の構成要素の親を表す型を使う。

MAKE_BUILDSPEC = {  # 一覧を作る CodeBuild の buildspec を定義する。
    "version": 0.2,  # コマンド間で作業ディレクトリを維持する buildspec 0.2 を使う。
    "env": {"shell": "bash"},  # 子スクリプトへ関数を引き継げる bash で実行する。
    "phases": {"build": {"commands": [  # ビルド段階で実行するコマンドの一覧を始める。
        'cd "$CODEBUILD_SRC_DIR/$SOURCE_DIRECTORY"',  # 取得したリポジトリ内のプロジェクトへ移動する。
        'bash build-rules.sh "$ENVIRONMENT_NAME"',  # ローカルと共通の入口で、指定環境のルールを作る。
    ]}},  # ビルド段階のコマンド一覧を閉じる。
    "artifacts": {  # 承認後のデプロイに渡す成果物を定義する。
        "base-directory": "$SOURCE_DIRECTORY",  # プロジェクトの場所を基準に成果物を集める。
        "files": [  # 成果物に含めるファイルの一覧を始める。
            "deploy-rules.sh", "command/aws-cli.sh", "command/set-s3-uri.sh",  # デプロイの入口と AWS CLI 設定・S3 宛先の部品を渡す。
            "command/publish-refresh-scripts.sh",  # チェックサムを作って S3 へ送る部品も渡す。
            "work/*/command/port_guard/refresh-*.sh",  # ビルドが作った IPv4・IPv6 の ipset 入れ替えスクリプトを渡す。
            "work/*/port_guard_whitelists/allow-*.txt",  # 今回のビルドで使用した個別許可の一覧を渡す。
            "work/*/port_guard_whitelists/last-refresh/*.txt",  # 次回の増減比較に使う、今回の一覧の記録を渡す。
        ],  # 成果物に含めるファイルの一覧を閉じる。
    },  # 成果物の設定を閉じる。
}  # 一覧を作る buildspec の定義を閉じる。
PUBLISH_BUILDSPEC = {  # S3 へ上げる CodeBuild の buildspec を定義する。
    "version": 0.2,  # デプロイ側も buildspec 0.2 を使う。
    "env": {"shell": "bash"},  # デプロイ側のコマンドも bash で実行する。
    "phases": {"build": {"commands": ['bash deploy-rules.sh "$ENVIRONMENT_NAME"']}},  # 承認済みの成果物にある入口で、指定環境のファイルを上げる。
}  # S3 へ上げる buildspec の定義を閉じる。


class ListRefreshPipelineStack(cdk.Stack):  # バケットを作らず、更新処理だけを持つスタックを定義する。
    def __init__(self, scope: Construct, stack_name: str) -> None:  # 親の構成要素とスタック名を受け取る。
        super().__init__(scope, stack_name, stack_name=stack_name,  # CloudFormation のスタックを指定した名前で初期化する。
                         synthesizer=cdk.BootstraplessSynthesizer(), analytics_reporting=False)  # アセット用バケットと bootstrap を不要にし、利用状況メタデータを付けない。
        environment = cdk.CfnParameter(self, "EnvironmentName", type="String",  # デプロイ時に環境名を受け取るパラメータを作る。
                                       allowed_values=["development", "staging", "production"]).value_as_string  # 環境名は既存の一覧がある3環境から選び、文字列として使う。
        artifact_name = cdk.CfnParameter(self, "PipelineBucketName", type="String").value_as_string  # 別スタックが出力した中間成果物用バケットの完全名を受け取る。
        rule_name = cdk.CfnParameter(self, "PublishBucketName", type="String").value_as_string  # ルールの配布先となるバケットの完全名を受け取る。
        connection = cdk.CfnParameter(self, "ConnectionArn", type="String").value_as_string  # 事前に認可した CodeConnections 接続の ARN を受け取る。
        repository = cdk.CfnParameter(self, "FullRepositoryId", type="String").value_as_string  # ソースの所有者とリポジトリ名を受け取る。
        branch = cdk.CfnParameter(self, "BranchName", type="String", default="main").value_as_string  # 取得するブランチを受け取り、省略時は main にする。
        directory = cdk.CfnParameter(self, "SourceDirectory", type="String", default=".").value_as_string  # リポジトリ内のプロジェクトの場所を受け取り、省略時は直下にする。
        approval = cdk.CfnParameter(self, "RequireApproval", type="String", default="true",  # 人の承認を入れるかを受け取り、省略時は入れる。
                                   allowed_values=["true", "false"])  # 承認の指定は文字列の true または false に限定する。
        retention = cdk.CfnParameter(self, "LogRetentionInDays", type="Number", default=90)  # ビルドログの保存日数を受け取り、省略時は90日にする。
        use_approval = cdk.CfnCondition(self, "UseApproval",  # 承認ステージを残すかを決める CloudFormation 条件を作る。
                                      expression=cdk.Fn.condition_equals(approval.value_as_string, "true"))  # RequireApproval が true の場合に、その条件を成立させる。
        artifacts = s3.Bucket.from_bucket_name(self, "Artifacts", artifact_name)  # 中間成果物用バケットを名前で参照し、このスタックでは作らない。
        rules = s3.Bucket.from_bucket_name(self, "Rules", rule_name)  # ルール用バケットも名前で参照し、このスタックでは作らない。
        prefix = f"port-guard/{environment}/current"  # 指定環境のルールを置く S3 キーの共通部分を作る。
        uri = f"s3://{rule_name}/{prefix}"  # ビルドとデプロイに渡す S3 URI を組み立てる。
        log_group = logs.LogGroup(self, "BuildLogs",  # 2つの CodeBuild が使う CloudWatch Logs のグループを作る。
                                 log_group_name=f"/aws/codebuild/port-guard-list-refresh-{environment}",  # 環境ごとに分けたロググループ名を指定する。
                                 retention=logs.RetentionDays.THREE_MONTHS,  # L2 の初期値として90日の保存期間を指定する。
                                 removal_policy=cdk.RemovalPolicy.DESTROY)  # パイプライン用スタックを削除した場合はロググループも削除する。
        log_group.node.default_child.retention_in_days = retention.value_as_number  # 保存日数をデプロイ時のパラメータで選べるよう、L1 の値に置き換える。

        def project(name, suffix, spec, timeout, extra=None):  # ビルド用とデプロイ用に共通する CodeBuild の設定をまとめる。
            variables = {"ENVIRONMENT_NAME": environment, "PORT_GUARD_S3_URI": uri, **(extra or {})}  # 両方に環境名と S3 URI を渡し、必要なら呼び出し側の変数を加える。
            return build.PipelineProject(  # 入出力を CodePipeline から受け渡す CodeBuild を作る。
                self, name, project_name=f"port-guard-list-refresh-{environment}-{suffix}",  # 構成要素の名前と、環境・役割が分かるプロジェクト名を付ける。
                build_spec=build.BuildSpec.from_object(spec), timeout=cdk.Duration.minutes(timeout),  # 辞書の buildspec と、役割に応じた実行時間の上限を指定する。
                grant_report_group_permissions=False,  # 使わないテストレポートの作成権限は自動で付けない。
                environment=build.BuildEnvironment(  # CodeBuild の実行環境を指定する。
                    build_image=build.LinuxBuildImage.from_code_build_image_id(  # AWS が提供する CodeBuild イメージを名前で参照する。
                        "aws/codebuild/amazonlinux-x86_64-standard:5.0"),  # Amazon Linux の標準ビルドイメージ 5.0 を使う。
                    compute_type=build.ComputeType.SMALL),  # 小さいコンピューティングタイプを使う。
                environment_variables={k: build.BuildEnvironmentVariable(value=v) for k, v in variables.items()},  # 環境変数を CodeBuild の環境変数オブジェクトに変換する。
                logging=build.LoggingOptions(cloud_watch=build.CloudWatchLoggingOptions(  # ビルドログを CloudWatch Logs に出す設定を始める。
                    log_group=log_group, prefix=suffix)),  # 共通ロググループ内で、make と publish のログを分ける。
            )  # 作成した CodeBuild プロジェクトを呼び出し側へ返す。

        make = project("MakeProject", "make", MAKE_BUILDSPEC, 15,  # 一覧を作るプロジェクトを、実行上限15分で作る。
                       {"SOURCE_DIRECTORY": directory, "FORCE": "0"})  # 一覧を作る側だけにソースの場所と FORCE の既定値を渡す。
        publish = project("PublishProject", "publish", PUBLISH_BUILDSPEC, 10)  # S3 へ上げるプロジェクトを、実行上限10分で作る。
        # 配布先の権限は明記する。make は読むだけ、publish はこの環境への PutObject だけ。
        make.add_to_role_policy(iam.PolicyStatement(  # 一覧を作るロールに、配布先から取得する権限を追加する。
            actions=["s3:GetObject"], resources=[rules.arn_for_objects(f"{prefix}/*")]))  # 取得できるオブジェクトを、この環境の current 配下だけにする。
        make.add_to_role_policy(iam.PolicyStatement(  # 前回分のファイル名を列挙するための権限を追加する。
            actions=["s3:ListBucket"], resources=[rules.bucket_arn],  # 対象をルール用バケットの一覧取得に限定する。
            conditions={"StringLike": {"s3:prefix": f"{prefix}/*"}}))  # 列挙できるキーの範囲を、この環境の current 配下に絞る。
        publish.add_to_role_policy(iam.PolicyStatement(  # S3 へ上げるロールに、配布先への書き込み権限を追加する。
            actions=["s3:PutObject"], resources=[rules.arn_for_objects(f"{prefix}/*")]))  # 書き込める場所を、この環境の current 配下だけにする。

        force = pipeline.Variable(variable_name="FORCE", default_value="0",  # パイプライン開始時に選べる FORCE 変数を作り、通常は0にする。
                                  description="Set 1 after reviewing a change above 5 percent.")  # 増減が5%を超えた場合に、確認後に1を指定する変数だと説明する。
        flow = pipeline.Pipeline(  # 更新処理をつなぐ CodePipeline を L2 で作る。
            self, "Pipeline", pipeline_name=f"port-guard-list-refresh-{environment}",  # 環境名が分かるパイプライン名を付ける。
            artifact_bucket=artifacts, cross_account_keys=False,  # 別スタックの成果物用バケットを使い、専用 KMS キーは作らない。
            pipeline_type=pipeline.PipelineType.V2, execution_mode=pipeline.ExecutionMode.QUEUED,  # V2 パイプラインを使い、同時実行の要求は順番待ちにする。
            restart_execution_on_update=False, use_pipeline_role_for_actions=True, variables=[force],  # 更新時の再実行を無効にし、共通ロールと FORCE 変数を使う。
        )  # パイプライン本体の設定を閉じる。
        source_files, made_files = pipeline.Artifact("SourceFiles"), pipeline.Artifact("MadeFiles")  # Git の取得結果と、ビルド後の成果物を区別する入れ物を作る。
        repo_parts = cdk.Fn.split("/", repository)  # L2 の所有者・リポジトリの引数に渡すため、リポジトリ指定を分ける。
        flow.add_stage(stage_name="Source", actions=[actions.CodeStarConnectionsSourceAction(  # Git からソースを取得するステージを追加する。
            action_name="Repository", connection_arn=connection,  # 取得アクション名と、使う CodeConnections 接続を指定する。
            owner=cdk.Fn.select(0, repo_parts), repo=cdk.Fn.select(1, repo_parts),  # 所有者とリポジトリをパラメータから取り出して L2 に渡す。
            branch=branch, output=source_files, trigger_on_push=False,  # ブランチと出力成果物を指定し、push による自動実行を止める。
        )])  # ソース取得のアクションとステージを閉じる。
        flow.add_to_role_policy(iam.PolicyStatement(  # パイプラインのロールに、接続を利用する権限を加える。
            actions=["codeconnections:UseConnection", "codestar-connections:UseConnection"],  # AWS の現行仕様に合わせ、新旧両方のサービス名で UseConnection を許可する。
            resources=[connection]))  # 接続の利用先を、指定した1つの ARN だけにする。
        flow.add_stage(stage_name="Make", actions=[actions.CodeBuildAction(  # 取得したソースから一覧を作るステージを追加する。
            action_name="BuildRules", project=make, input=source_files, outputs=[made_files],  # 一覧用 CodeBuild にソースを渡し、できた結果を別の成果物に保存する。
            environment_variables={"FORCE": build.BuildEnvironmentVariable(value=force.reference())},  # 開始時の FORCE 変数を、この実行の CodeBuild に渡す。
        )])  # 一覧を作るアクションとステージを閉じる。
        flow.add_stage(stage_name="Check", actions=[actions.ManualApprovalAction(action_name="HumanCheck")])  # 人が件数と増減を確かめて承認するステージを追加する。
        flow.add_stage(stage_name="Publish", actions=[actions.CodeBuildAction(  # 承認済みの成果物を S3 に上げるステージを追加する。
            action_name="DeployRules", project=publish, input=made_files,  # S3 用 CodeBuild に、一覧を作ったときの成果物を渡す。
        )])  # デプロイのアクションとステージを閉じる。
        # デプロイ時に承認の有無を選ぶため、このステージだけ L1 の条件にする。
        flow.node.default_child.add_property_override("Stages.2", cdk.Fn.condition_if(  # 3番目の承認ステージを、CloudFormation の条件付き定義に置き換える。
            use_approval.logical_id,  # 承認を使うかを決める条件の論理 ID を指定する。
            {"Name": "Check", "Actions": [{  # 条件が成立したときに残す Check ステージの定義を始める。
                "Name": "HumanCheck",  # 人が操作する承認アクション名を指定する。
                "ActionTypeId": {"Category": "Approval", "Owner": "AWS", "Provider": "Manual", "Version": "1"},  # AWS 標準の Manual 承認アクションとして定義する。
                "Configuration": {"CustomData": "Review counts and changes in the make build log before publishing."},  # 承認する人に、ビルドログの件数と増減を確認するよう表示する。
            }]}, cdk.Aws.NO_VALUE))  # 承認不要なら AWS::NoValue によりステージごと省略する。
        # グループ階層を含むリポジトリ名も、入力した値をそのまま渡す。
        flow.node.default_child.add_property_override("Stages.0.Actions.0.Configuration.FullRepositoryId", repository)  # L2 で分割した値ではなく、入力されたリポジトリ名全体を最終設定に戻す。
        cdk.CfnOutput(self, "PipelineName", value=flow.pipeline_name)  # 作成したパイプライン名をスタックの出力に載せる。
        cdk.CfnOutput(self, "PublishLocation", value=uri)  # ルールを配布する S3 URI をスタックの出力に載せる。
