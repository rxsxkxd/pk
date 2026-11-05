package stacks

import (
	"fmt"

	"ami-publish/internal/definitions"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// NewLaunchTemplateStack は、起動テンプレートのスタック（<app>-<env>-launch-template）を定義する。
//
// パラメータ AmiId / AppVersion は AMI 公開パイプラインが変更セットで更新する（初回は空でよい）。
// AMI 公開ツールは、変更セットに AWS::EC2::LaunchTemplate の Modify 以外が含まれたら中止するので、
// パラメータに依存するのは起動テンプレートだけにする。UserData・サブネットは入れない。
func NewLaunchTemplateStack(scope constructs.Construct, environment definitions.Environment) awscdk.Stack {
	application := environment.ApplicationName
	settings := environment.LaunchTemplate
	stack := newStack(scope, environment.LaunchTemplateStackName(),
		fmt.Sprintf("%s launch template (%s). ImageId is updated by the AMI publish pipeline.",
			application, environment.Name), environment)

	amiID := awscdk.NewCfnParameter(stack, jsii.String("AmiId"), &awscdk.CfnParameterProps{
		Type:           jsii.String("String"),
		Default:        jsii.String(""),
		AllowedPattern: jsii.String(`^(ami-[0-9a-f]{8,17})?$`),
		Description:    jsii.String("AMI created by the AMI publish pipeline. Leave empty on the first deployment."),
	})
	appVersion := awscdk.NewCfnParameter(stack, jsii.String("AppVersion"), &awscdk.CfnParameterProps{
		Type:           jsii.String("String"),
		Default:        jsii.String(""),
		AllowedPattern: jsii.String(`^(v[0-9]+\.[0-9]+\.[0-9]+)?$`),
		Description:    jsii.String("Application release version contained in the AMI (e.g. v1.2.3). Leave empty on the first deployment."),
	})
	hasAmiID := awscdk.NewCfnCondition(stack, jsii.String("HasAmiId"), &awscdk.CfnConditionProps{
		Expression: awscdk.Fn_ConditionNot(awscdk.Fn_ConditionEquals(amiID.ValueAsString(), jsii.String(""))),
	})
	ifHasAmiID := func(whenSet, whenEmpty any) *string {
		return awscdk.Token_AsString(awscdk.Fn_ConditionIf(hasAmiID.LogicalId(), whenSet, whenEmpty), nil)
	}

	// 本番インスタンスのロール（インスタンスプロファイルは、起動テンプレートに role を渡すと CDK が作る）
	role := awsiam.NewRole(stack, jsii.String("InstanceRole"), &awsiam.RoleProps{
		AssumedBy: awsiam.NewServicePrincipal(jsii.String("ec2.amazonaws.com"), nil),
		ManagedPolicies: &[]awsiam.IManagedPolicy{
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonSSMManagedInstanceCore")),
		},
	})

	launchTemplate := awsec2.NewLaunchTemplate(stack, jsii.String("LaunchTemplate"), &awsec2.LaunchTemplateProps{
		LaunchTemplateName: jsii.String(environment.LaunchTemplateName()),
		VersionDescription: ifHasAmiID(awscdk.Fn_Sub(jsii.String(application+" ${AppVersion}"), nil),
			application+" (AMI not set)"),
		InstanceType:  awsec2.NewInstanceType(jsii.String(settings.InstanceType)),
		Role:          role,
		RequireImdsv2: jsii.Bool(true),
	})
	for index, securityGroupID := range settings.SecurityGroupIDs {
		launchTemplate.Connections().AddSecurityGroup(awsec2.SecurityGroup_FromSecurityGroupId(
			stack, jsii.String(fmt.Sprintf("SecurityGroup%d", index)), jsii.String(securityGroupID), nil))
	}
	// AMI は初回は空（指定しない）にするため、L2 の machineImage ではなく、L1 のプロパティを条件付きで上書きする
	cfnLaunchTemplate := launchTemplate.Node().DefaultChild().(awsec2.CfnLaunchTemplate)
	cfnLaunchTemplate.AddPropertyOverride(jsii.String("LaunchTemplateData.ImageId"),
		awscdk.Fn_ConditionIf(hasAmiID.LogicalId(), amiID.ValueAsString(), awscdk.Aws_NO_VALUE()))

	// 起動テンプレートと、そこから起動したインスタンス・ボリュームに付くタグ
	awscdk.Tags_Of(launchTemplate).Add(jsii.String("App"), jsii.String(application), nil)
	awscdk.Tags_Of(launchTemplate).Add(jsii.String("AppVersion"), ifHasAmiID(appVersion.ValueAsString(), "none"), nil)

	// スタック名: AMI 公開パイプラインのスタックが参照する（権限の対象）
	exportOutput(stack, "StackName", stack.StackName(), environment.LaunchTemplateStackExport("StackName"))
	// 起動テンプレートの ID: フェーズ 2 のサーバーのスタックが参照する（作成後に変わらない）
	exportOutput(stack, "LaunchTemplateId", launchTemplate.LaunchTemplateId(),
		environment.LaunchTemplateStackExport("LaunchTemplateId"))
	// バージョンは AMI の公開のたびに変わるため Export しない（参照されると更新できなくなる）
	output(stack, "LaunchTemplateVersion", launchTemplate.LatestVersionNumber())
	return stack
}
