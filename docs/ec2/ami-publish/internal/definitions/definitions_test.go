package definitions

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const testConfiguration = `
environments:
  staging:
    aws_region: ap-northeast-1
    application_name: myapp
    release_instance_id: i-0123456789abcdef0
    pipeline:
      source_connection_arn: arn:aws:codeconnections:ap-northeast-1:123456789012:connection/abc
      source_repository_id: example-org/ami-publish
      source_branch_name: main
      log_retention_days: 90
    launch_template:
      instance_type: t3.small
      security_group_ids: [sg-0123456789abcdef0]
    health_check:
      url: http://localhost/up
    timeouts:
      codebuild_minutes: 120
      image_available_seconds: 3600
      instance_online_seconds: 900
      health_check_seconds: 300
      stack_update_seconds: 1800
      poll_interval_seconds: 15
      progress_log_interval_seconds: 60
`

// setUpRepository は、設定値ファイルを置いた一時ディレクトリを作る。
func setUpRepository(t *testing.T, configuration string) (root string, configPath string) {
	t.Helper()
	root = t.TempDir()
	configPath = filepath.Join(root, "ami_publish.yml")
	if err := os.WriteFile(configPath, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	return root, configPath
}

func generate(t *testing.T) (map[string][]byte, string) {
	t.Helper()
	root, configPath := setUpRepository(t, testConfiguration)
	configuration, err := LoadConfiguration(configPath)
	if err != nil {
		t.Fatalf("LoadConfiguration: %v", err)
	}
	files, err := GenerateAll(configuration)
	if err != nil {
		t.Fatalf("GenerateAll: %v", err)
	}
	result := map[string][]byte{}
	for _, file := range files {
		result[file.Path] = file.Content
	}
	return result, root
}

// parse は生成された YAML を汎用の構造として読む。
func parse(t *testing.T, content []byte) map[string]any {
	t.Helper()
	var document map[string]any
	if err := yaml.Unmarshal(content, &document); err != nil {
		t.Fatalf("生成された YAML を読めない: %v", err)
	}
	return document
}

func dig(t *testing.T, document any, keys ...string) any {
	t.Helper()
	current := document
	for _, key := range keys {
		mapping, ok := current.(map[string]any)
		if !ok {
			t.Fatalf("%s の手前がマッピングではない: %#v", key, current)
		}
		current, ok = mapping[key]
		if !ok {
			t.Fatalf("キー %s がない（%s）", key, strings.Join(keys, "."))
		}
	}
	return current
}

func TestGenerateAllProducesExpectedFiles(t *testing.T) {
	files, _ := generate(t)
	for _, path := range []string{
		"codebuild/ami-publish-buildspec.yml",
		"cloudformation/staging/launch-template-stack.yml",
		"cloudformation/staging/ami-publish-pipeline-stack.yml",
		"cloudformation/staging/health-check-stack.yml",
	} {
		content, ok := files[path]
		if !ok {
			t.Errorf("%s が生成されていない", path)
			continue
		}
		if !bytes.HasPrefix(content, []byte(generatedFileHeader)) {
			t.Errorf("%s に生成物の注意書きがない", path)
		}
	}
	if len(files) != 4 {
		t.Errorf("生成ファイル数 = %d, want 4", len(files))
	}
}

// 生成し直しても差分が出ないこと（差分でレビューする前提）。
func TestGenerateAllIsDeterministic(t *testing.T) {
	first, _ := generate(t)
	for range 5 {
		second, _ := generate(t)
		for path, content := range first {
			if !bytes.Equal(content, second[path]) {
				t.Fatalf("%s の生成結果が毎回同じではない", path)
			}
		}
	}
}

// CloudFormation テンプレートの最上位のキーが、定義した順（Parameters → Resources → Outputs）で出力されること。
func TestTopLevelKeyOrder(t *testing.T) {
	files, _ := generate(t)
	content := string(files["cloudformation/staging/launch-template-stack.yml"])
	positions := []int{
		strings.Index(content, "\nAWSTemplateFormatVersion:"),
		strings.Index(content, "\nDescription:"),
		strings.Index(content, "\nParameters:"),
		strings.Index(content, "\nResources:"),
		strings.Index(content, "\nOutputs:"),
	}
	for index := 1; index < len(positions); index++ {
		if positions[index-1] < 0 || positions[index] < positions[index-1] {
			t.Fatalf("最上位のキーの順序が崩れている: %v", positions)
		}
	}
}

func TestLaunchTemplateStack(t *testing.T) {
	files, _ := generate(t)
	document := parse(t, files["cloudformation/staging/launch-template-stack.yml"])

	for _, name := range []string{"AmiId", "AppVersion"} {
		dig(t, document, "Parameters", name)
	}
	resources := dig(t, document, "Resources").(map[string]any)
	for name, resource := range resources {
		switch resourceType := dig(t, resource, "Type"); resourceType {
		case "AWS::EC2::LaunchTemplate", "AWS::IAM::Role", "AWS::IAM::InstanceProfile":
		default:
			t.Errorf("起動テンプレートのスタックに想定外のリソース %s（%v）がある", name, resourceType)
		}
	}

	data := dig(t, document, "Resources", "LaunchTemplate", "Properties", "LaunchTemplateData").(map[string]any)
	// 初回は AmiId を省略でき、そのときは ImageId を入れない（Fn::If と AWS::NoValue）。
	for _, name := range []string{"AmiId", "AppVersion"} {
		if got := dig(t, document, "Parameters", name, "Default"); got != "" {
			t.Errorf("%s の既定値 = %v, want 空（初回は省略できる）", name, got)
		}
	}
	dig(t, document, "Conditions", "HasAmiId")
	imageID := dig(t, data, "ImageId", "Fn::If").([]any)
	if imageID[0] != "HasAmiId" || dig(t, imageID[1], "Ref") != "AmiId" || dig(t, imageID[2], "Ref") != "AWS::NoValue" {
		t.Errorf("ImageId = %v, want Fn::If [HasAmiId, Ref AmiId, AWS::NoValue]", imageID)
	}
	if got := dig(t, data, "MetadataOptions", "HttpTokens"); got != "required" {
		t.Errorf("HttpTokens = %v, want required（IMDSv2 必須）", got)
	}
	// 後から Auto Scaling グループで使えるよう、サブネットやネットワークインターフェイスを指定しない。
	// UserData も指定しない。
	for _, key := range []string{"NetworkInterfaces", "SubnetId", "UserData"} {
		if _, ok := data[key]; ok {
			t.Errorf("起動テンプレートに %s を指定しない", key)
		}
	}
	dig(t, document, "Outputs", "LaunchTemplateVersion")
}

func TestPipelineStack(t *testing.T) {
	files, _ := generate(t)
	document := parse(t, files["cloudformation/staging/ami-publish-pipeline-stack.yml"])

	pipeline := dig(t, document, "Resources", "Pipeline", "Properties")
	if got := dig(t, pipeline, "PipelineType"); got != "V2" {
		t.Errorf("PipelineType = %v", got)
	}
	if got := dig(t, pipeline, "ExecutionMode"); got != "QUEUED" {
		t.Errorf("ExecutionMode = %v, want QUEUED（AMI の作成を重ねない）", got)
	}
	variables := dig(t, pipeline, "Variables").([]any)
	var names []string
	for _, variable := range variables {
		names = append(names, dig(t, variable, "Name").(string))
	}
	if strings.Join(names, ",") != "VERSION,HEALTH_CHECK,VERIFIED" {
		t.Errorf("パイプライン変数 = %v", names)
	}

	stages := dig(t, pipeline, "Stages").([]any)
	source := dig(t, stages[0], "Actions").([]any)[0]
	if got := dig(t, source, "Configuration", "DetectChanges"); got != false {
		t.Errorf("DetectChanges = %v, want false（push で自動起動しない）", got)
	}
	publish := dig(t, stages[1], "Actions").([]any)[0]
	environmentVariables := dig(t, publish, "Configuration", "EnvironmentVariables").(string)
	for _, want := range []string{"#{variables.VERSION}", "#{variables.VERIFIED}", "#{variables.HEALTH_CHECK}", "#{codepipeline.PipelineExecutionId}"} {
		if !strings.Contains(environmentVariables, want) {
			t.Errorf("CodeBuild に %s が渡されていない: %s", want, environmentVariables)
		}
	}

	project := dig(t, document, "Resources", "CodeBuildProject", "Properties")
	if got := dig(t, project, "Environment", "Image"); got != codeBuildImage {
		t.Errorf("Image = %v, want %s", got, codeBuildImage)
	}
	if got := dig(t, project, "TimeoutInMinutes"); got != 120 {
		t.Errorf("TimeoutInMinutes = %v, want 120（timeouts.codebuild_minutes）", got)
	}
	if got := dig(t, project, "ConcurrentBuildLimit"); got != 1 {
		t.Errorf("ConcurrentBuildLimit = %v, want 1", got)
	}
	if got := dig(t, project, "Source", "BuildSpec"); got != BuildspecPath {
		t.Errorf("BuildSpec = %v", got)
	}

	// CodeBuild には任意のコマンドを送る AWS-RunShellScript を許可しない。
	content := string(files["cloudformation/staging/ami-publish-pipeline-stack.yml"])
	if strings.Contains(content, "AWS-RunShellScript") {
		t.Error("CodeBuild のロールに AWS-RunShellScript を許可しない")
	}
	// 停止中のリリース用インスタンスは確認のために起動するが、停止はパイプラインの外で行う。
	if !strings.Contains(content, "ec2:StartInstances") {
		t.Error("停止中のリリース用インスタンスを起動する権限がない")
	}
	// リリース用インスタンスのロールの許可を、ポリシーシミュレーターで確認する（ステップ 0 の後）。
	for _, action := range []string{"iam:GetInstanceProfile", "iam:SimulatePrincipalPolicy"} {
		if !strings.Contains(content, action) {
			t.Errorf("リリース用インスタンスのロールの許可を確認する権限 %s がない", action)
		}
	}
	if strings.Contains(content, "ec2:StopInstances") {
		t.Error("パイプラインにインスタンスを停止する権限を与えない")
	}
	if !strings.Contains(content, "document/myapp-staging-health-check") {
		t.Error("ヘルスチェックの SSM ドキュメントの実行が許可されていない")
	}
	dig(t, document, "Outputs", "LaunchTemplateStackServiceRoleArn")
}

// healthCheckScript は、ヘルスチェックのスタックの SSM ドキュメントのコマンドを 1 つの文字列にする。
func healthCheckScript(t *testing.T, content []byte) (string, map[string]any) {
	t.Helper()
	document := parse(t, content)
	properties := dig(t, document, "Resources", "HealthCheckDocument", "Properties")
	if got := dig(t, properties, "Name"); got != "myapp-staging-health-check" {
		t.Errorf("Name = %v", got)
	}
	steps := dig(t, properties, "Content", "mainSteps").([]any)
	joined := ""
	for _, command := range dig(t, steps[0], "inputs", "runCommand").([]any) {
		joined += command.(string) + "\n"
	}
	return joined, document
}

func TestHealthCheckStackWithoutBasicAuth(t *testing.T) {
	files, _ := generate(t)
	script, document := healthCheckScript(t, files["cloudformation/staging/health-check-stack.yml"])

	if !strings.Contains(script, "curl -sS -o /dev/null -w '%{http_code}' http://localhost/up") {
		t.Errorf("ヘルスチェックの URL が使われていない:\n%s", script)
	}
	if strings.Contains(script, "get-parameter") || strings.Contains(script, "-K -") {
		t.Errorf("Basic 認証を指定していないのに認証の処理がある:\n%s", script)
	}
	if _, ok := dig(t, document, "Resources").(map[string]any)["BasicAuthParameterReadPolicy"]; ok {
		t.Error("Basic 認証を指定していないのに管理ポリシーがある")
	}
}

// Basic 認証の情報は SSM Parameter Store から実行時に取り出し、curl には標準入力（-K -）で渡す。
func TestHealthCheckStackWithBasicAuth(t *testing.T) {
	_, configPath := setUpRepository(t, strings.Replace(testConfiguration,
		"      url: http://localhost/up\n",
		"      url: http://localhost/up\n      basic_auth_parameter_name: /myapp/staging/health-check/basic-auth\n", 1))
	configuration, err := LoadConfiguration(configPath)
	if err != nil {
		t.Fatal(err)
	}
	files, err := GenerateAll(configuration)
	if err != nil {
		t.Fatal(err)
	}
	var content []byte
	for _, file := range files {
		if file.Path == "cloudformation/staging/health-check-stack.yml" {
			content = file.Content
		}
	}
	script, document := healthCheckScript(t, content)

	for _, want := range []string{
		"aws ssm get-parameter --region ap-northeast-1 --name '/myapp/staging/health-check/basic-auth' --with-decryption",
		"basic_auth | curl -K - -sS",
	} {
		if !strings.Contains(script, want) {
			t.Errorf("%q がない:\n%s", want, script)
		}
	}
	// 認証情報をコマンドライン引数（curl -u）で渡さない。
	if strings.Contains(script, " -u ") {
		t.Errorf("認証情報を curl -u で渡さない:\n%s", script)
	}

	policy := dig(t, document, "Resources", "BasicAuthParameterReadPolicy", "Properties", "PolicyDocument")
	statement := dig(t, policy, "Statement").([]any)[0]
	if got := dig(t, statement, "Action"); got != "ssm:GetParameter" {
		t.Errorf("Action = %v", got)
	}
	resource := dig(t, statement, "Resource", "Fn::Sub").(string)
	if !strings.HasSuffix(resource, ":parameter/myapp/staging/health-check/basic-auth") {
		t.Errorf("Resource = %v", resource)
	}
	dig(t, document, "Outputs", "BasicAuthParameterReadPolicyArn")
}

func TestBuildspec(t *testing.T) {
	files, _ := generate(t)
	document := parse(t, files["codebuild/ami-publish-buildspec.yml"])
	// Ruby は runtime-versions ではなく、イメージに入っている rbenv でイメージにある 3.4 系を選ぶ。
	install := dig(t, document, "phases", "install").(map[string]any)
	if _, ok := install["runtime-versions"]; ok {
		t.Error("runtime-versions を使わない")
	}
	installCommands := dig(t, install, "commands").([]any)
	if !strings.Contains(installCommands[0].(string), "rbenv local "+codeBuildRubyVersion) {
		t.Errorf("install の最初で rbenv local %s を実行する: %v", codeBuildRubyVersion, installCommands)
	}
	exported := dig(t, document, "env", "exported-variables").([]any)
	if len(exported) != 2 || exported[0] != "AMI_ID" || exported[1] != "LAUNCH_TEMPLATE_VERSION" {
		t.Errorf("exported-variables = %v", exported)
	}
	commands := dig(t, document, "phases", "build", "commands").([]any)
	if !strings.HasPrefix(commands[0].(string), "bundle exec ruby bin/ami_publish run ") {
		t.Errorf("AMI 公開ツールを ruby コマンド経由で呼んでいない: %v", commands[0])
	}
}

func TestDifferences(t *testing.T) {
	root, configPath := setUpRepository(t, testConfiguration)
	configuration, err := LoadConfiguration(configPath)
	if err != nil {
		t.Fatal(err)
	}
	files, err := GenerateAll(configuration)
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(root, "generated")

	differences, err := Differences(output, files)
	if err != nil {
		t.Fatal(err)
	}
	if len(differences) != len(files) {
		t.Errorf("未生成のファイルがすべて検出されていない: %v", differences)
	}

	if err := WriteAll(output, files); err != nil {
		t.Fatal(err)
	}
	if differences, _ := Differences(output, files); len(differences) != 0 {
		t.Errorf("書き出した直後なのに差分がある: %v", differences)
	}

	edited := filepath.Join(output, "codebuild", "ami-publish-buildspec.yml")
	if err := os.WriteFile(edited, []byte("edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(output, "cloudformation", "removed-environment", "launch-template-stack.yml")
	if err := os.MkdirAll(filepath.Dir(stale), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stale, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	differences, err = Differences(output, files)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"内容が異なる: codebuild/ami-publish-buildspec.yml",
		"生成対象にない: cloudformation/removed-environment/launch-template-stack.yml",
	}
	if strings.Join(differences, "\n") != strings.Join(want, "\n") {
		t.Errorf("差分 = %v, want %v", differences, want)
	}
}

func TestLoadConfigurationRejectsInvalidValues(t *testing.T) {
	cases := map[string]struct {
		replace, with, wantMessage string
	}{
		"未知のキー":             {"    aws_region:", "    unknown_key: x\n    aws_region:", "unknown_key"},
		"インスタンス ID の形式":     {"i-0123456789abcdef0", "instance-1", "release_instance_id の形式が不正"},
		"ヘルスチェックの待機時間":      {"health_check_seconds: 300", "health_check_seconds: 60", "timeouts.health_check_seconds"},
		"URL に使えない文字":       {"http://localhost/up", "http://localhost/up;rm", "health_check.url の形式が不正"},
		"パラメーター名が / で始まらない": {"      url: http://localhost/up\n", "      url: http://localhost/up\n      basic_auth_parameter_name: myapp/basic-auth\n", "basic_auth_parameter_name の形式が不正"},
		"アプリケーション名の大文字":     {"application_name: myapp", "application_name: MyApp", "application_name の形式が不正"},
		"aws で始まる":          {"application_name: myapp", "application_name: awsapp", "aws / amazon で始めない"},
		"名前として使わない旧項目":      {"      url: http://localhost/up", "      stack_name: x\n      url: http://localhost/up", "stack_name"},
	}
	for name, testCase := range cases {
		t.Run(name, func(t *testing.T) {
			_, configPath := setUpRepository(t, strings.Replace(testConfiguration, testCase.replace, testCase.with, 1))
			_, err := LoadConfiguration(configPath)
			if err == nil || !strings.Contains(err.Error(), testCase.wantMessage) {
				t.Errorf("err = %v, want %q を含むエラー", err, testCase.wantMessage)
			}
		})
	}
}

func TestMapPanicsOnInvalidDefinition(t *testing.T) {
	for name, arguments := range map[string][]any{
		"数が合わない":    {"Key"},
		"キーが文字列でない": {1, "value"},
	} {
		t.Run(name, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Error("panic しなかった")
				}
			}()
			M(arguments...)
		})
	}
}

// 名前は application_name と環境名から自動で決まる。Ruby の AMI 公開ツールのテスト
// （spec/ami_publish/configuration_spec.rb）も同じ名前を期待しており、両方で命名規則が一致していることを確かめる。
func TestDerivedNames(t *testing.T) {
	_, configPath := setUpRepository(t, testConfiguration)
	configuration, err := LoadConfiguration(configPath)
	if err != nil {
		t.Fatal(err)
	}
	environment := configuration.Environments["staging"]
	want := map[string]string{
		"AMI 公開パイプラインのスタック":       "myapp-staging-ami-publish-pipeline",
		"CodePipeline のパイプライン":    "myapp-staging-ami-publish",
		"CodeBuild プロジェクト":        "myapp-staging-ami-publish",
		"CloudWatch Logs のロググループ": "/myapp/staging/ami-publish",
		"起動テンプレートのスタック":           "myapp-staging-launch-template",
		"起動テンプレート":                "myapp-staging",
		"ヘルスチェックのスタック":            "myapp-staging-health-check",
		"ヘルスチェックの SSM ドキュメント":     "myapp-staging-health-check",
	}
	names := environment.DerivedNames()
	if len(names) != len(want) {
		t.Fatalf("名前の数 = %d, want %d", len(names), len(want))
	}
	for _, pair := range names {
		if want[pair[0]] != pair[1] {
			t.Errorf("%s = %q, want %q", pair[0], pair[1], want[pair[0]])
		}
	}
}
