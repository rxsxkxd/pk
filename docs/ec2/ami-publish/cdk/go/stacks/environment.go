// Package stacks は、AMI 公開パイプラインの仕組みの 4 つのスタックを CDK（L2 の構成要素）で定義する。
//
// スタック名・リソースの名前・Export の名前は、仕組みの生成ツールと同じ命名規則（internal/definitions の naming.go）で決める。
// スタック間の参照は、CDK の自動の参照（名前が自動で決まる Export）を使わず、命名規則どおりの名前の Export と
// Fn::ImportValue で行う。AMI 公開ツール（Ruby）がスタック名・出力・Export の名前を前提にしているため。
package stacks

import (
	"ami-publish/internal/definitions"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// DefineEnvironment は、1 環境分の 4 つのスタックを定義する。
// デプロイの順（リリース用インスタンス・ヘルスチェック・起動テンプレート → AMI 公開パイプライン）は、
// Export の参照の順と同じ。CDK のスタックの依存関係としては宣言しない（デプロイは AWS CLI で行うため）。
func DefineEnvironment(scope constructs.Construct, environment definitions.Environment) {
	NewReleaseInstanceStack(scope, environment)
	NewHealthCheckStack(scope, environment)
	NewLaunchTemplateStack(scope, environment)
	NewPipelineStack(scope, environment)
}

// newStack は、命名規則どおりの名前のスタックを作る。
//   - ブートストラップのバージョンの確認（CheckBootstrapVersion）を入れない: cdk bootstrap をしていないアカウントにも、
//     AWS CLI でデプロイできるようにする（S3 に置くファイル（asset）を使わないので、ブートストラップは不要）
//   - CDKMetadata を入れない: 生成ツールの出力と同じく、テンプレートには定義したリソースだけを入れる
func newStack(scope constructs.Construct, stackName, description string, environment definitions.Environment) awscdk.Stack {
	return awscdk.NewStack(scope, jsii.String(stackName), &awscdk.StackProps{
		StackName:   jsii.String(stackName),
		Description: jsii.String(description),
		Env:         &awscdk.Environment{Region: jsii.String(environment.AWSRegion)},
		Synthesizer: awscdk.NewDefaultStackSynthesizer(&awscdk.DefaultStackSynthesizerProps{
			GenerateBootstrapVersionRule: jsii.Bool(false),
		}),
		AnalyticsReporting: jsii.Bool(false),
	})
}

// exportOutput は、命名規則どおりの名前で Export する出力を作る。
func exportOutput(stack awscdk.Stack, id string, value *string, exportName string) {
	awscdk.NewCfnOutput(stack, jsii.String(id), &awscdk.CfnOutputProps{
		Value:      value,
		ExportName: jsii.String(exportName),
	})
}

// output は、Export しない出力を作る。
func output(stack awscdk.Stack, id string, value *string) {
	awscdk.NewCfnOutput(stack, jsii.String(id), &awscdk.CfnOutputProps{Value: value})
}

// importValue は、命名規則どおりの名前の Export を参照する。
func importValue(exportName string) *string {
	return awscdk.Fn_ImportValue(jsii.String(exportName))
}

// sub は Fn::Sub。arn:${AWS::Partition}:... のような ARN を組み立てる。
func sub(body string, variables map[string]*string) *string {
	if variables == nil {
		return awscdk.Fn_Sub(jsii.String(body), nil)
	}
	converted := make(map[string]*string, len(variables))
	for key, value := range variables {
		converted[key] = value
	}
	return awscdk.Fn_Sub(jsii.String(body), &converted)
}
