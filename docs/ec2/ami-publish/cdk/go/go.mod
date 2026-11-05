module ami-publish/cdk/go

go 1.25

require (
	ami-publish v0.0.0
	github.com/aws/aws-cdk-go/awscdk/v2 v2.275.0
	github.com/aws/constructs-go/constructs/v10 v10.8.1
	github.com/aws/jsii-runtime-go v1.142.0
)

// 設定値の読み込み・検証と命名規則は、仕組みの生成ツール（ami-publish/internal/definitions）のものを使う
replace ami-publish => ../..
