package definitions

import "fmt"

// LaunchTemplateStack は起動テンプレートのスタックの CloudFormation テンプレートを返す。
//
// スタックに含めるのは、起動テンプレートと、それが参照する IAM ロール・インスタンスプロファイルだけ。
// Auto Scaling グループなど実際のインスタンスを構築するリソースは含めない（スコープ外）。
// パラメータ AmiId / AppVersion は AMI 公開パイプラインが更新し、テンプレート本体は担当者がデプロイする。
// 初回のデプロイでは AmiId / AppVersion を省略できる（空）。そのときは起動テンプレートに AMI を入れず、
// 最初のパイプラインの実行で AMI が入る（初回用の AMI を用意しなくてよい）。
//
// 後から Auto Scaling グループで使えるよう、サブネットや固定のプライベート IP は指定しない。
// UserData は指定しない（起動時に必要な処理は AMI 側に持たせる）。
func LaunchTemplateStack(environment Environment) Map {
	settings := environment.LaunchTemplate
	application := environment.ApplicationName

	instanceRoleProperties := M(
		"AssumeRolePolicyDocument", M(
			"Version", "2012-10-17",
			"Statement", []any{M(
				"Effect", "Allow",
				"Principal", M("Service", "ec2.amazonaws.com"),
				"Action", "sts:AssumeRole",
			)},
		),
		"ManagedPolicyArns", []any{
			Sub("arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"),
		},
	)

	launchTemplateData := M(
		"ImageId", If(hasAmiID, Ref("AmiId"), NoValue()),
		"InstanceType", settings.InstanceType,
		"IamInstanceProfile", M("Arn", GetAtt("InstanceProfile", "Arn")),
		"SecurityGroupIds", stringsToAny(settings.SecurityGroupIDs),
		"MetadataOptions", M(
			"HttpEndpoint", "enabled",
			"HttpTokens", "required",
		),
		"TagSpecifications", []any{
			M("ResourceType", "instance", "Tags", applicationTags(application)),
			M("ResourceType", "volume", "Tags", applicationTags(application)),
		},
	)

	return M(
		"AWSTemplateFormatVersion", "2010-09-09",
		"Description", fmt.Sprintf("%s launch template (%s). ImageId is updated by the AMI publish pipeline.",
			application, environment.Name),
		"Parameters", M(
			"AmiId", M(
				"Type", "String",
				"Default", "",
				"AllowedPattern", `^(ami-[0-9a-f]{8,17})?$`,
				"Description", "AMI created by the AMI publish pipeline. Leave empty on the first deployment.",
			),
			"AppVersion", M(
				"Type", "String",
				"Default", "",
				"AllowedPattern", `^(v[0-9]+\.[0-9]+\.[0-9]+)?$`,
				"Description", "Application release version contained in the AMI (e.g. v1.2.3). Leave empty on the first deployment.",
			),
		),
		"Conditions", M(
			hasAmiID, Not(Equals(Ref("AmiId"), "")),
		),
		"Resources", M(
			"InstanceRole", M(
				"Type", "AWS::IAM::Role",
				"Properties", instanceRoleProperties,
			),
			"InstanceProfile", M(
				"Type", "AWS::IAM::InstanceProfile",
				"Properties", M("Roles", []any{Ref("InstanceRole")}),
			),
			"LaunchTemplate", M(
				"Type", "AWS::EC2::LaunchTemplate",
				"Properties", M(
					"LaunchTemplateName", environment.LaunchTemplateName(),
					"VersionDescription", If(hasAmiID, Sub(application+" ${AppVersion}"), application+" (AMI not set)"),
					"LaunchTemplateData", launchTemplateData,
				),
			),
		),
		"Outputs", M(
			"LaunchTemplateId", M("Value", Ref("LaunchTemplate")),
			"LaunchTemplateVersion", M("Value", GetAtt("LaunchTemplate", "LatestVersionNumber")),
		),
	)
}

// hasAmiID は、パラメータ AmiId が指定されているか（初回のデプロイでは空）の条件名。
const hasAmiID = "HasAmiId"

func applicationTags(application string) []any {
	return []any{
		M("Key", "App", "Value", application),
		M("Key", "AppVersion", "Value", If(hasAmiID, Ref("AppVersion"), "none")),
	}
}

func stringsToAny(values []string) []any {
	result := make([]any, len(values))
	for index, value := range values {
		result[index] = value
	}
	return result
}
