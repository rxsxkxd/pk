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
      stack_name: myapp-staging-ami-publish-pipeline
      pipeline_name: myapp-staging-ami-publish
      codebuild_project_name: myapp-staging-ami-publish
      codebuild_image: aws/codebuild/standard:7.0
      codebuild_timeout_minutes: 120
      source_connection_arn: arn:aws:codeconnections:ap-northeast-1:123456789012:connection/abc
      source_repository_id: example-org/ami-publish
      source_branch_name: main
      log_group_name: /myapp/staging/ami-publish
      log_retention_days: 90
    launch_template:
      stack_name: myapp-staging-launch-template
      launch_template_name: myapp-staging
      instance_type: t3.small
      security_group_ids: [sg-0123456789abcdef0]
      secret_arns: [arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:myapp/staging/env-AbCdEf]
      user_data_file: user_data.sh
    ssm_documents:
      stack_name: myapp-staging-ssm-documents
      health_check_document_name: MyApp-Staging-HealthCheck
      health_check_url: http://localhost/up
    timeouts:
      image_available_seconds: 3600
      instance_online_seconds: 900
      health_check_seconds: 300
      stack_update_seconds: 1800
      poll_interval_seconds: 15
`

// setUpRepository は、設定値ファイルと UserData ファイルを置いた一時ディレクトリを作る。
func setUpRepository(t *testing.T, configuration string) (root string, configPath string) {
	t.Helper()
	root = t.TempDir()
	configPath = filepath.Join(root, "ami_publish.yml")
	if err := os.WriteFile(configPath, []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "user_data.sh"), []byte("#!/bin/bash\necho hello\n"), 0o644); err != nil {
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
	files, err := GenerateAll(configuration, root)
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
		"cloudformation/staging/ssm-documents-stack.yml",
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
	if got := dig(t, data, "ImageId", "Ref"); got != "AmiId" {
		t.Errorf("ImageId = %v, want Ref AmiId", got)
	}
	if got := dig(t, data, "MetadataOptions", "HttpTokens"); got != "required" {
		t.Errorf("HttpTokens = %v, want required（IMDSv2 必須）", got)
	}
	// 後から Auto Scaling グループで使えるよう、サブネットやネットワークインターフェイスを指定しない。
	for _, key := range []string{"NetworkInterfaces", "SubnetId"} {
		if _, ok := data[key]; ok {
			t.Errorf("起動テンプレートに %s を指定しない", key)
		}
	}
	if got := dig(t, data, "UserData", "Fn::Base64"); got != "#!/bin/bash\necho hello\n" {
		t.Errorf("UserData = %q", got)
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
	if strings.Join(names, ",") != "VERSION,VERIFIED" {
		t.Errorf("パイプライン変数 = %v", names)
	}

	stages := dig(t, pipeline, "Stages").([]any)
	source := dig(t, stages[0], "Actions").([]any)[0]
	if got := dig(t, source, "Configuration", "DetectChanges"); got != false {
		t.Errorf("DetectChanges = %v, want false（push で自動起動しない）", got)
	}
	publish := dig(t, stages[1], "Actions").([]any)[0]
	environmentVariables := dig(t, publish, "Configuration", "EnvironmentVariables").(string)
	for _, want := range []string{"#{variables.VERSION}", "#{variables.VERIFIED}", "#{codepipeline.PipelineExecutionId}"} {
		if !strings.Contains(environmentVariables, want) {
			t.Errorf("CodeBuild に %s が渡されていない: %s", want, environmentVariables)
		}
	}

	project := dig(t, document, "Resources", "CodeBuildProject", "Properties")
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
	if !strings.Contains(content, "document/MyApp-Staging-HealthCheck") {
		t.Error("ヘルスチェックの SSM ドキュメントの実行が許可されていない")
	}
	dig(t, document, "Outputs", "LaunchTemplateStackServiceRoleArn")
}

func TestSSMDocumentsStack(t *testing.T) {
	files, _ := generate(t)
	document := parse(t, files["cloudformation/staging/ssm-documents-stack.yml"])
	properties := dig(t, document, "Resources", "HealthCheckDocument", "Properties")
	if got := dig(t, properties, "Name"); got != "MyApp-Staging-HealthCheck" {
		t.Errorf("Name = %v", got)
	}
	steps := dig(t, properties, "Content", "mainSteps").([]any)
	commands := dig(t, steps[0], "inputs", "runCommand").([]any)
	joined := ""
	for _, command := range commands {
		joined += command.(string) + "\n"
	}
	if !strings.Contains(joined, "curl -fsS -o /dev/null http://localhost/up") {
		t.Errorf("ヘルスチェックの URL が使われていない:\n%s", joined)
	}
}

func TestBuildspec(t *testing.T) {
	files, _ := generate(t)
	document := parse(t, files["codebuild/ami-publish-buildspec.yml"])
	if got := dig(t, document, "phases", "install", "runtime-versions", "ruby"); got != "3.4" {
		t.Errorf("ruby = %v, want 3.4", got)
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
	files, err := GenerateAll(configuration, root)
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
		"未知のキー":         {"    aws_region:", "    unknown_key: x\n    aws_region:", "unknown_key"},
		"インスタンス ID の形式": {"i-0123456789abcdef0", "instance-1", "release_instance_id の形式が不正"},
		"ヘルスチェックの待機時間":  {"health_check_seconds: 300", "health_check_seconds: 60", "timeouts.health_check_seconds"},
		"URL に使えない文字":   {"http://localhost/up", "http://localhost/up;rm", "health_check_url の形式が不正"},
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
