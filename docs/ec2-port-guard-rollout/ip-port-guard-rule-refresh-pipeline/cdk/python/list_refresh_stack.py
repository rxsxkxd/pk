"""パイプライン用スタック（環境ごとに 1 つ）。

ルールジェネレーターのリポジトリからソースを取り、次の順に流す。

    Source → Make（build-rules.sh）→ Check（人の承認。RequireApproval=false で省く）→ Publish（deploy-rules.sh）

YAML 版 cloudformation/list-refresh-pipeline.yml と、パラメータ・動き・権限をそろえている（tests/test_stack.py で照合する）。
YAML 版との違いは 1 つだけで、ルールジェネレーターのリポジトリのホスト（GitHub か CodeCommit）を、デプロイ時の
パラメータではなく合成時の引数 source_provider で選ぶ（CDK の L2 のソースアクションを、権限の自動付与ごと使うため）。

このスタックが作るもの:
  - パイプラインの受け渡しバケット（このパイプラインだけが使う。スタックを消しても残す）
  - CodeBuild 2 つ（Make・Publish）とそれぞれのロール、ビルドのログ
  - CodePipeline
  - 定期実行の規則とそのロール（ScheduleExpression が空でないとき）
作らないもの:
  - ルールのデプロイ先バケット（手で作ったものを、名前の先頭部分 RuleDeployBucketNamePrefix から組み立てて参照する）
  - 通知の SNS のトピック（既にあるものの ARN を NotificationTopicArn で受け取る）
"""

import aws_cdk as cdk
from aws_cdk import aws_codebuild as build
from aws_cdk import aws_codecommit as codecommit
from aws_cdk import aws_codepipeline as pipeline
from aws_cdk import aws_codepipeline_actions as actions
from aws_cdk import aws_events as events
from aws_cdk import aws_iam as iam
from aws_cdk import aws_logs as logs
from aws_cdk import aws_s3 as s3
from constructs import Construct

ENVIRONMENTS = ["development", "staging", "production"]
SOURCE_PROVIDERS = ("GitHub", "CodeCommit")
BUILD_IMAGE = "aws/codebuild/amazonlinux-x86_64-standard:5.0"

# Make から Publish に渡すファイル（プロジェクトの中の場所）。Make のビルドの最後に handoff/ へ写して成果物にする。
# artifacts の base-directory で環境変数が展開されるとはドキュメントに書かれていないので、SourceDirectory の値に頼らない。
HANDOFF_FILES = [
    "deploy-rules.sh",                                   # デプロイの入口
    "command/aws-cli.sh",                                # AWS CLI の設定
    "command/set-s3-uri.sh",                             # ルールのデプロイ先の URI を決める
    "command/publish-refresh-scripts.sh",                # 上げる（照合の値 SHA256SUMS を最後）
    "work/*/command/port_guard/refresh-*.sh",            # 今回作った ipset 入れ替えスクリプト
    "work/*/port_guard_whitelists/allow-*.txt",          # 今回使った個別許可の一覧の写し
    "work/*/port_guard_whitelists/last-refresh/*.txt",   # 次回の増減の比較に使う、今回の一覧の記録
]

# build-rules.sh の表示を build-rules.log にも残し、失敗したら（増減の確認で止まったときを含む）
# 止まった理由と増減を SNS へ送ってから、ビルドを失敗で終える。YAML 版の折り返した 1 行と同じ文字列にしている。
MAKE_COMMAND = (
    'set -o pipefail; '
    'bash build-rules.sh "$ENVIRONMENT_NAME" 2>&1 | tee "$CODEBUILD_SRC_DIR/build-rules.log" '
    '|| { bash command/notify-make-failure.sh "$CODEBUILD_SRC_DIR/build-rules.log"; exit 1; }'
)
MAKE_BUILDSPEC = {
    "version": 0.2,
    "env": {"shell": "bash"},
    "phases": {"build": {"commands": [
        'cd "$CODEBUILD_SRC_DIR/$SOURCE_DIRECTORY"',
        MAKE_COMMAND,
        'mkdir -p "$CODEBUILD_SRC_DIR/handoff"',
        "tar -cf - " + " ".join(HANDOFF_FILES) + ' | tar -xf - -C "$CODEBUILD_SRC_DIR/handoff"',
    ]}},
    "artifacts": {"base-directory": "handoff", "files": ["**/*"]},
}
# Publish は Make の成果物だけで流す。ルールを作り直さない。
PUBLISH_BUILDSPEC = {
    "version": 0.2,
    "env": {"shell": "bash"},
    "phases": {"build": {"commands": ['bash deploy-rules.sh "$ENVIRONMENT_NAME"']}},
}
APPROVAL_MESSAGE = "Review counts and changes in the make build log before publishing."


class ListRefreshPipelineStack(cdk.Stack):
    def __init__(self, scope: Construct, stack_name: str, source_provider: str = "GitHub") -> None:
        if source_provider not in SOURCE_PROVIDERS:
            raise ValueError(f"source_provider must be one of {SOURCE_PROVIDERS}: {source_provider}")
        # アセットや bootstrap を使わない（合成したテンプレートを AWS CLI でもそのまま反映できる）
        super().__init__(scope, stack_name, stack_name=stack_name,
                         synthesizer=cdk.BootstraplessSynthesizer(), analytics_reporting=False)
        self.source_provider = source_provider

        self._add_parameters()
        handoff_bucket = self._add_handoff_bucket()
        make, publish = self._add_build_projects()
        flow = self._add_pipeline(handoff_bucket, make, publish)
        self._add_schedule(flow)
        cdk.CfnOutput(self, "PipelineName", value=flow.pipeline_name)
        cdk.CfnOutput(self, "PipelineHandoffBucketName", value=handoff_bucket.bucket_name)
        cdk.CfnOutput(self, "RuleDeployLocation", value=self.rule_deploy_location)

    # ---- パラメータと条件 -------------------------------------------------------------
    # YAML 版と同じ名前・既定値。ホストに関わるパラメータは、合成時に選んだホストの分だけを作る。
    def _add_parameters(self) -> None:
        def parameter(name, **props):
            return cdk.CfnParameter(self, name, type=props.pop("type", "String"), **props)

        self.env_name = parameter("EnvironmentName", allowed_values=ENVIRONMENTS).value_as_string
        rule_prefix = parameter("RuleDeployBucketNamePrefix", default="ip-port-guard-rules").value_as_string
        if self.source_provider == "GitHub":
            self.connection = parameter("ConnectionArn").value_as_string
            self.repository = parameter("FullRepositoryId").value_as_string
        else:
            self.repository = parameter("CodeCommitRepositoryName").value_as_string
        self.branch = parameter("BranchName", default="main").value_as_string
        self.source_directory = parameter("SourceDirectory", default=".").value_as_string
        approval = parameter("RequireApproval", default="true", allowed_values=["true", "false"]).value_as_string
        self.log_retention = parameter("LogRetentionInDays", type="Number", default=90).value_as_number
        self.schedule = parameter("ScheduleExpression", default="cron(0 0 ? * MON,THU *)").value_as_string
        self.topic = parameter("NotificationTopicArn", default="").value_as_string

        self.use_approval = cdk.CfnCondition(self, "UseApproval", expression=cdk.Fn.condition_equals(approval, "true"))
        self.use_schedule = cdk.CfnCondition(
            self, "UseSchedule", expression=cdk.Fn.condition_not(cdk.Fn.condition_equals(self.schedule, "")))
        self.use_notification = cdk.CfnCondition(
            self, "UseNotification", expression=cdk.Fn.condition_not(cdk.Fn.condition_equals(self.topic, "")))

        # ルールのデプロイ先バケットは、アカウントのリージョナル名前空間で手で作ってある。名前はローカルの入口スクリプトと同じ形
        rule_bucket_name = f"{rule_prefix}-{cdk.Aws.ACCOUNT_ID}-{cdk.Aws.REGION}-an"
        self.rule_bucket = s3.Bucket.from_bucket_name(self, "Rules", rule_bucket_name)
        self.rule_deploy_prefix = f"port-guard/{self.env_name}/current"
        self.rule_deploy_location = f"s3://{rule_bucket_name}/{self.rule_deploy_prefix}"

    # ---- パイプラインの受け渡しバケット ---------------------------------------------------
    # 名前は後ろに付く部分（31 文字）も含めて 63 文字まで。先頭部分は最長の development で 30 文字。
    def _add_handoff_bucket(self) -> s3.Bucket:
        return s3.Bucket(
            self, "PipelineHandoffBucket",
            bucket_name_prefix=f"port-guard-handoff-{self.env_name}",
            bucket_namespace=s3.BucketNamespace.ACCOUNT_REGIONAL,
            versioned=True,
            encryption=s3.BucketEncryption.S3_MANAGED,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            object_ownership=s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
            removal_policy=cdk.RemovalPolicy.RETAIN,
            lifecycle_rules=[s3.LifecycleRule(id="expire-noncurrent-versions",
                                              noncurrent_version_expiration=cdk.Duration.days(90))],
        )

    # ---- CodeBuild（Make・Publish）とその権限 ------------------------------------------
    # ルールのデプロイ先の権限: Make は読むだけ（前回分の一覧を取る）、Publish はこの環境の current/ への書き込みだけ。
    # パイプラインの受け渡しバケットの権限は、CDK がパイプラインとの接続から自動で付ける。
    def _add_build_projects(self) -> tuple[build.PipelineProject, build.PipelineProject]:
        log_group = logs.LogGroup(self, "BuildLogs",
                                  log_group_name=f"/aws/codebuild/port-guard-list-refresh-{self.env_name}",
                                  retention=logs.RetentionDays.THREE_MONTHS,
                                  removal_policy=cdk.RemovalPolicy.DESTROY)
        log_group.node.default_child.retention_in_days = self.log_retention  # 保存日数はパラメータで選ぶ

        def project(name, suffix, spec, timeout_minutes, variables):
            return build.PipelineProject(
                self, name,
                project_name=f"port-guard-list-refresh-{self.env_name}-{suffix}",
                build_spec=build.BuildSpec.from_object(spec),
                timeout=cdk.Duration.minutes(timeout_minutes),
                grant_report_group_permissions=False,
                environment=build.BuildEnvironment(
                    build_image=build.LinuxBuildImage.from_code_build_image_id(BUILD_IMAGE),
                    compute_type=build.ComputeType.SMALL),
                environment_variables={k: build.BuildEnvironmentVariable(value=v) for k, v in variables.items()},
                logging=build.LoggingOptions(cloud_watch=build.CloudWatchLoggingOptions(log_group=log_group, prefix=suffix)),
            )

        common = {"ENVIRONMENT_NAME": self.env_name, "PORT_GUARD_S3_URI": self.rule_deploy_location}
        make = project("MakeProject", "make", MAKE_BUILDSPEC, 15,
                       common | {"SOURCE_DIRECTORY": self.source_directory, "FORCE": "0"})
        publish = project("PublishProject", "publish", PUBLISH_BUILDSPEC, 10, common)

        objects = self.rule_bucket.arn_for_objects(f"{self.rule_deploy_prefix}/*")
        make.add_to_role_policy(iam.PolicyStatement(actions=["s3:GetObject"], resources=[objects]))
        make.add_to_role_policy(iam.PolicyStatement(
            actions=["s3:ListBucket"], resources=[self.rule_bucket.bucket_arn],
            conditions={"StringLike": {"s3:prefix": f"{self.rule_deploy_prefix}/*"}}))
        publish.add_to_role_policy(iam.PolicyStatement(actions=["s3:PutObject"], resources=[objects]))

        # 通知: トピックが指定されたときだけ、Make に環境変数 NOTIFICATION_TOPIC_ARN と sns:Publish の権限を付ける
        make.node.default_child.add_property_override("Environment.EnvironmentVariables.4", cdk.Fn.condition_if(
            self.use_notification.logical_id,
            {"Name": "NOTIFICATION_TOPIC_ARN", "Type": "PLAINTEXT", "Value": self.topic},
            cdk.Aws.NO_VALUE))
        notification = iam.Policy(self, "MakeNotificationPolicy", roles=[make.role], statements=[
            iam.PolicyStatement(actions=["sns:Publish"], resources=[self.topic])])
        notification.node.default_child.cfn_options.condition = self.use_notification
        return make, publish

    # ---- パイプライン --------------------------------------------------------------------
    def _add_pipeline(self, handoff_bucket, make, publish) -> pipeline.Pipeline:
        force = pipeline.Variable(variable_name="FORCE", default_value="0",
                                  description="Set 1 after reviewing a change above 5 percent.")
        flow = pipeline.Pipeline(
            self, "Pipeline",
            pipeline_name=f"port-guard-list-refresh-{self.env_name}",
            artifact_bucket=handoff_bucket, cross_account_keys=False,
            pipeline_type=pipeline.PipelineType.V2, execution_mode=pipeline.ExecutionMode.QUEUED,
            restart_execution_on_update=False, use_pipeline_role_for_actions=True, variables=[force],
        )
        source_files, made_files = pipeline.Artifact("SourceFiles"), pipeline.Artifact("MadeFiles")
        flow.add_stage(stage_name="Source", actions=[self._source_action(source_files)])
        flow.add_stage(stage_name="Make", actions=[actions.CodeBuildAction(
            action_name="BuildRules", project=make, input=source_files, outputs=[made_files],
            environment_variables={"FORCE": build.BuildEnvironmentVariable(value=force.reference())})])
        flow.add_stage(stage_name="Check", actions=[actions.ManualApprovalAction(action_name="HumanCheck")])
        flow.add_stage(stage_name="Publish", actions=[actions.CodeBuildAction(
            action_name="DeployRules", project=publish, input=made_files)])

        cfn = flow.node.default_child
        # 承認の有無をデプロイ時に選ぶため、Check のステージだけ L1 の条件付きの定義に置き換える
        cfn.add_property_override("Stages.2", cdk.Fn.condition_if(self.use_approval.logical_id, {
            "Name": "Check",
            "Actions": [{"Name": "HumanCheck",
                         "ActionTypeId": {"Category": "Approval", "Owner": "AWS", "Provider": "Manual", "Version": "1"},
                         "Configuration": {"CustomData": APPROVAL_MESSAGE}}],
        }, cdk.Aws.NO_VALUE))
        # ソースは YAML 版と同じく zip で受け渡す
        cfn.add_property_override("Stages.0.Actions.0.Configuration.OutputArtifactFormat", "CODE_ZIP")
        if self.source_provider == "GitHub":
            # L2 には所有者とリポジトリを分けて渡したが、グループ階層を含む名前もそのまま使えるよう、入力どおりに戻す
            cfn.add_property_override("Stages.0.Actions.0.Configuration.FullRepositoryId", self.repository)
            flow.add_to_role_policy(iam.PolicyStatement(
                actions=["codeconnections:UseConnection", "codestar-connections:UseConnection"],
                resources=[self.connection]))
        return flow

    # ルールジェネレーターのリポジトリから取るアクション。どちらも自動では開始しない（人か定期実行で開始する）。
    def _source_action(self, output: pipeline.Artifact) -> pipeline.IAction:
        if self.source_provider == "GitHub":
            parts = cdk.Fn.split("/", self.repository)
            return actions.CodeStarConnectionsSourceAction(
                action_name="Repository", connection_arn=self.connection,
                owner=cdk.Fn.select(0, parts), repo=cdk.Fn.select(1, parts),
                branch=self.branch, output=output, trigger_on_push=False)
        repository = codecommit.Repository.from_repository_name(self, "Repository", self.repository)
        return actions.CodeCommitSourceAction(
            action_name="Repository", repository=repository,
            branch=self.branch, output=output, trigger=actions.CodeCommitTrigger.NONE)

    # ---- 定期実行 ------------------------------------------------------------------------
    # ScheduleExpression が空でないときだけ作る。EventBridge が専用のロールで、このパイプラインだけを開始する。
    def _add_schedule(self, flow: pipeline.Pipeline) -> None:
        role = iam.Role(self, "ScheduleRole", assumed_by=iam.ServicePrincipal("events.amazonaws.com"),
                        inline_policies={"start-pipeline": iam.PolicyDocument(statements=[iam.PolicyStatement(
                            actions=["codepipeline:StartPipelineExecution"], resources=[flow.pipeline_arn])])})
        rule = events.CfnRule(self, "ScheduleRule",
                              description=f"Scheduled start of port-guard-list-refresh-{self.env_name}",
                              schedule_expression=self.schedule, state="ENABLED",
                              targets=[events.CfnRule.TargetProperty(id="pipeline", arn=flow.pipeline_arn,
                                                                     role_arn=role.role_arn)])
        role.node.default_child.cfn_options.condition = self.use_schedule
        rule.cfn_options.condition = self.use_schedule
