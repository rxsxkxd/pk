package definitions

// 命名規則。アプリケーション名（application_name）と環境名から、リソースの名前を自動で決める。
//
// Ruby の AMI 公開ツール（lib/ami_publish/configuration.rb）も同じ規則で名前を決めている。
// 規則を変えるときは両方を直し、両方のテストで同じ名前になることを確かめる。
//
// 例: application_name が myapp、環境名が staging の場合
//
//	AMI 公開パイプラインのスタック     myapp-staging-ami-publish-pipeline
//	CodePipeline のパイプライン        myapp-staging-ami-publish
//	CodeBuild プロジェクト             myapp-staging-ami-publish
//	CloudWatch Logs のロググループ     /myapp/staging/ami-publish
//	起動テンプレートのスタック         myapp-staging-launch-template
//	起動テンプレート                   myapp-staging
//	ヘルスチェックのスタック           myapp-staging-health-check
//	ヘルスチェックの SSM ドキュメント  myapp-staging-health-check
//	リリース用インスタンスの IAM ロールのスタック  myapp-staging-release-instance

func (e Environment) namePrefix() string { return e.ApplicationName + "-" + e.Name }

// PipelineStackName は AMI 公開パイプラインのスタックの名前。
func (e Environment) PipelineStackName() string { return e.namePrefix() + "-ami-publish-pipeline" }

// PipelineName は CodePipeline のパイプラインの名前。
func (e Environment) PipelineName() string { return e.namePrefix() + "-ami-publish" }

// CodeBuildProjectName は CodeBuild プロジェクトの名前。
func (e Environment) CodeBuildProjectName() string { return e.namePrefix() + "-ami-publish" }

// LogGroupName は CodeBuild のログと、ヘルスチェックの出力を保存する CloudWatch Logs のロググループの名前。
func (e Environment) LogGroupName() string {
	return "/" + e.ApplicationName + "/" + e.Name + "/ami-publish"
}

// LaunchTemplateStackName は起動テンプレートのスタックの名前。
func (e Environment) LaunchTemplateStackName() string { return e.namePrefix() + "-launch-template" }

// LaunchTemplateName は起動テンプレートの名前。
func (e Environment) LaunchTemplateName() string { return e.namePrefix() }

// HealthCheckStackName はヘルスチェックのスタックの名前。
func (e Environment) HealthCheckStackName() string { return e.namePrefix() + "-health-check" }

// HealthCheckDocumentName はヘルスチェックの SSM ドキュメントの名前。
func (e Environment) HealthCheckDocumentName() string { return e.namePrefix() + "-health-check" }

// ReleaseInstanceStackName は、リリース用インスタンスの IAM ロールのスタックの名前
// （デプロイ用シェルスクリプトの up / down には含めない）。
func (e Environment) ReleaseInstanceStackName() string { return e.namePrefix() + "-release-instance" }

// スタック間の参照に使う Export の名前（アカウント・リージョンの中で一意）。「<スタック名>:<項目>」とする。
// Export している値は、参照されている間は変更・削除できないため、変わらない値だけを Export する
// （起動テンプレートのバージョンは Export しない）。

// LaunchTemplateStackExport は、起動テンプレートのスタックの Export の名前。
func (e Environment) LaunchTemplateStackExport(item string) string {
	return e.LaunchTemplateStackName() + ":" + item
}

// HealthCheckStackExport は、ヘルスチェックのスタックの Export の名前。
func (e Environment) HealthCheckStackExport(item string) string {
	return e.HealthCheckStackName() + ":" + item
}

// DerivedNames は自動で決めた名前の一覧（生成時に表示する）。
func (e Environment) DerivedNames() [][2]string {
	return [][2]string{
		{"AMI 公開パイプラインのスタック", e.PipelineStackName()},
		{"CodePipeline のパイプライン", e.PipelineName()},
		{"CodeBuild プロジェクト", e.CodeBuildProjectName()},
		{"CloudWatch Logs のロググループ", e.LogGroupName()},
		{"起動テンプレートのスタック", e.LaunchTemplateStackName()},
		{"起動テンプレート", e.LaunchTemplateName()},
		{"ヘルスチェックのスタック", e.HealthCheckStackName()},
		{"ヘルスチェックの SSM ドキュメント", e.HealthCheckDocumentName()},
		{"リリース用インスタンスの IAM ロールのスタック", e.ReleaseInstanceStackName()},
	}
}
