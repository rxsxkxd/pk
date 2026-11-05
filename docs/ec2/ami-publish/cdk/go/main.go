// AMI 公開パイプラインの仕組みの CDK 版（Go）。
//
// 設定値ファイル（config/ami_publish.yml）の全環境について、4 つのスタックを定義する。
// CDK は CloudFormation テンプレートを作る（cdk synth）ためだけに使い、デプロイは今までどおり担当者が
// AWS CLI で変更セットを作って確認してから反映する（決定事項 D9。cdk bootstrap は不要）。
// L2 の構成要素で書くので、論理 ID は仕組みの生成ツール（cmd/generate-definitions）の出力と異なる。
// そのため、生成ツールでデプロイ済みの環境を、このテンプレートで更新しない（新しい環境向け）。
//
//	cd cdk/go && cdk synth                       # cdk.out/ に全環境のテンプレートを出力する
//	cdk synth -c config=../../config/other.yml   # 設定値ファイルを変える
package main

import (
	"fmt"
	"os"

	"ami-publish/cdk/go/stacks"
	"ami-publish/internal/definitions"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/jsii-runtime-go"
)

func main() {
	defer jsii.Close()

	app := awscdk.NewApp(nil)
	configPath := "../../config/ami_publish.yml"
	if value, ok := app.Node().TryGetContext(jsii.String("config")).(string); ok && value != "" {
		configPath = value
	}
	// 設定値の検証（未知の項目のエラーを含む）は、仕組みの生成ツールと同じ
	configuration, err := definitions.LoadConfiguration(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	for _, name := range configuration.EnvironmentNames() {
		stacks.DefineEnvironment(app, configuration.Environments[name])
	}
	app.Synth(nil)
}
