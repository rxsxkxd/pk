"""起動テンプレートのスタック（<app>-<env>-launch-template）。"""

from __future__ import annotations

import aws_cdk as cdk
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_iam as iam
from constructs import Construct

from ..configuration import Environment
from .common import NamedStack


class LaunchTemplateStack(NamedStack):
    """パラメータ AmiId / AppVersion は AMI 公開パイプラインが変更セットで更新する（初回は空でよい）。

    AMI 公開ツールは、変更セットに AWS::EC2::LaunchTemplate の Modify 以外が含まれたら中止するので、
    パラメータに依存するのは起動テンプレートだけにする。UserData・サブネットは入れない。
    """

    def __init__(self, scope: Construct, environment: Environment) -> None:
        application = environment.application_name
        settings = environment.launch_template
        super().__init__(
            scope,
            environment.launch_template_stack_name,
            f"{application} launch template ({environment.name}). ImageId is updated by the AMI publish pipeline.",
            environment,
        )

        ami_id = cdk.CfnParameter(
            self,
            "AmiId",
            type="String",
            default="",
            allowed_pattern=r"^(ami-[0-9a-f]{8,17})?$",
            description="AMI created by the AMI publish pipeline. Leave empty on the first deployment.",
        )
        app_version = cdk.CfnParameter(
            self,
            "AppVersion",
            type="String",
            default="",
            allowed_pattern=r"^(v[0-9]+\.[0-9]+\.[0-9]+)?$",
            description="Application release version contained in the AMI (e.g. v1.2.3). "
            "Leave empty on the first deployment.",
        )
        has_ami_id = cdk.CfnCondition(
            self, "HasAmiId", expression=cdk.Fn.condition_not(cdk.Fn.condition_equals(ami_id.value_as_string, ""))
        )

        def if_has_ami_id(when_set, when_empty) -> str:
            return cdk.Token.as_string(cdk.Fn.condition_if(has_ami_id.logical_id, when_set, when_empty))

        # 本番インスタンスのロール（インスタンスプロファイルは、起動テンプレートに role を渡すと CDK が作る）
        role = iam.Role(
            self,
            "InstanceRole",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[iam.ManagedPolicy.from_aws_managed_policy_name("AmazonSSMManagedInstanceCore")],
        )

        # 既存のセキュリティグループ（設定値で 1 つ以上）。L2 は作るときに 1 つ渡さないと connections を使えないので、
        # 1 つ目は作るときに渡し、2 つ目からは connections で足す
        security_groups = [
            ec2.SecurityGroup.from_security_group_id(self, f"SecurityGroup{index}", security_group_id)
            for index, security_group_id in enumerate(settings.security_group_ids)
        ]
        launch_template = ec2.LaunchTemplate(
            self,
            "LaunchTemplate",
            launch_template_name=environment.launch_template_name,
            version_description=if_has_ami_id(cdk.Fn.sub(f"{application} ${{AppVersion}}"), f"{application} (AMI not set)"),
            instance_type=ec2.InstanceType(settings.instance_type),
            role=role,
            require_imdsv2=True,
            security_group=security_groups[0],
        )
        for security_group in security_groups[1:]:
            launch_template.connections.add_security_group(security_group)
        # AMI は初回は空（指定しない）にするため、L2 の machine_image ではなく、L1 のプロパティを条件付きで上書きする
        cfn_launch_template: ec2.CfnLaunchTemplate = launch_template.node.default_child
        cfn_launch_template.add_property_override(
            "LaunchTemplateData.ImageId",
            cdk.Fn.condition_if(has_ami_id.logical_id, ami_id.value_as_string, cdk.Aws.NO_VALUE),
        )
        # 合成時の検証は ImageId を空の文字列（AmiId の既定値）として形式を確かめて警告する。空のときは Fn::If で
        # ImageId を指定しない（AWS::NoValue）ので、承知済みとして扱う
        cdk.Validations.of(cfn_launch_template).acknowledge(
            cdk.Acknowledgment(
                id="CloudFormation-Validate::E1152", reason="ImageId is omitted by Fn::If when AmiId is empty"
            )
        )

        # 起動テンプレートと、そこから起動したインスタンス・ボリュームに付くタグ
        cdk.Tags.of(launch_template).add("App", application)
        cdk.Tags.of(launch_template).add("AppVersion", if_has_ami_id(app_version.value_as_string, "none"))
        # L2 が自動で付ける Name タグ（構成要素のパス）は付けない（生成ツールの出力と同じく、インスタンスの名前は決めない）
        cdk.Tags.of(launch_template).remove("Name")

        # スタック名: AMI 公開パイプラインのスタックが参照する（権限の対象）
        self.export_output("StackName", self.stack_name, environment.launch_template_stack_export("StackName"))
        # 起動テンプレートの ID: フェーズ 2 のサーバーのスタックが参照する（作成後に変わらない）
        self.export_output(
            "LaunchTemplateId",
            launch_template.launch_template_id,
            environment.launch_template_stack_export("LaunchTemplateId"),
        )
        # バージョンは AMI の公開のたびに変わるため Export しない（参照されると更新できなくなる）
        self.output("LaunchTemplateVersion", launch_template.latest_version_number)
