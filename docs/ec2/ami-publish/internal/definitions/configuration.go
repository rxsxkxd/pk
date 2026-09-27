package definitions

import (
	"bytes"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Configuration は config/ami_publish.yml の内容。Ruby の AMI 公開ツールも同じファイルを読む。
type Configuration struct {
	Environments map[string]Environment `yaml:"environments"`
}

// Environment は 1 環境分の設定値。
type Environment struct {
	AWSRegion         string                 `yaml:"aws_region"`
	ApplicationName   string                 `yaml:"application_name"`
	ReleaseInstanceID string                 `yaml:"release_instance_id"`
	Pipeline          PipelineSettings       `yaml:"pipeline"`
	LaunchTemplate    LaunchTemplateSettings `yaml:"launch_template"`
	SSMDocuments      SSMDocumentsSettings   `yaml:"ssm_documents"`
	Timeouts          TimeoutSettings        `yaml:"timeouts"`
}

// PipelineSettings は AMI 公開パイプラインのスタックの設定値。
type PipelineSettings struct {
	StackName               string `yaml:"stack_name"`
	PipelineName            string `yaml:"pipeline_name"`
	CodeBuildProjectName    string `yaml:"codebuild_project_name"`
	CodeBuildImage          string `yaml:"codebuild_image"`
	CodeBuildTimeoutMinutes int    `yaml:"codebuild_timeout_minutes"`
	SourceConnectionARN     string `yaml:"source_connection_arn"`
	SourceRepositoryID      string `yaml:"source_repository_id"`
	SourceBranchName        string `yaml:"source_branch_name"`
	LogGroupName            string `yaml:"log_group_name"`
	LogRetentionDays        int    `yaml:"log_retention_days"`
}

// LaunchTemplateSettings は起動テンプレートのスタックの設定値。
type LaunchTemplateSettings struct {
	StackName          string   `yaml:"stack_name"`
	LaunchTemplateName string   `yaml:"launch_template_name"`
	InstanceType       string   `yaml:"instance_type"`
	SecurityGroupIDs   []string `yaml:"security_group_ids"`
	SecretARNs         []string `yaml:"secret_arns"`
	UserDataFile       string   `yaml:"user_data_file"`
}

// SSMDocumentsSettings は SSM ドキュメントのスタックの設定値。
type SSMDocumentsSettings struct {
	StackName               string `yaml:"stack_name"`
	HealthCheckDocumentName string `yaml:"health_check_document_name"`
	HealthCheckURL          string `yaml:"health_check_url"`
}

// TimeoutSettings は AMI 公開ツールの待機時間（秒）。生成には使わないが、値の検証はここでも行う。
type TimeoutSettings struct {
	ImageAvailableSeconds int `yaml:"image_available_seconds"`
	InstanceOnlineSeconds int `yaml:"instance_online_seconds"`
	HealthCheckSeconds    int `yaml:"health_check_seconds"`
	StackUpdateSeconds    int `yaml:"stack_update_seconds"`
	PollIntervalSeconds   int `yaml:"poll_interval_seconds"`
}

var (
	environmentNamePattern  = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	resourceNamePattern     = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]*$`)
	instanceIDPattern       = regexp.MustCompile(`^i-[0-9a-f]{8,17}$`)
	securityGroupIDPattern  = regexp.MustCompile(`^sg-[0-9a-f]{8,17}$`)
	logGroupNamePattern     = regexp.MustCompile(`^/[A-Za-z0-9_./-]+$`)
	documentNamePattern     = regexp.MustCompile(`^[A-Za-z0-9_.-]{3,128}$`)
	healthCheckURLPattern   = regexp.MustCompile(`^https?://[A-Za-z0-9._:/-]+$`)
	repositoryIDPattern     = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
	arnPattern              = regexp.MustCompile(`^arn:aws[a-z-]*:[a-z0-9-]+:`)
	codeBuildImagePattern   = regexp.MustCompile(`^[A-Za-z0-9._/:-]+$`)
	userDataFilePathPattern = regexp.MustCompile(`^[A-Za-z0-9_./-]+$`)
)

// LoadConfiguration は設定値ファイルを読み、値を検証する。
// 未知のキーはエラーにする（書き間違いを生成時に見つけるため）。
func LoadConfiguration(path string) (Configuration, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return Configuration{}, fmt.Errorf("設定値ファイルを読めない: %w", err)
	}
	decoder := yaml.NewDecoder(bytes.NewReader(content))
	decoder.KnownFields(true)
	var configuration Configuration
	if err := decoder.Decode(&configuration); err != nil {
		return Configuration{}, fmt.Errorf("%s: %w", path, err)
	}
	if err := configuration.Validate(); err != nil {
		return Configuration{}, fmt.Errorf("%s: %w", path, err)
	}
	return configuration, nil
}

// EnvironmentNames は環境名を名前順で返す（生成順を固定するため）。
func (c Configuration) EnvironmentNames() []string {
	names := make([]string, 0, len(c.Environments))
	for name := range c.Environments {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Validate は全環境の設定値を検証し、問題をまとめて返す。
func (c Configuration) Validate() error {
	if len(c.Environments) == 0 {
		return fmt.Errorf("environments に環境が 1 つもない")
	}
	var problems []string
	for _, name := range c.EnvironmentNames() {
		if !environmentNamePattern.MatchString(name) {
			problems = append(problems, fmt.Sprintf("環境名 %q は英小文字・数字・ハイフンにする", name))
		}
		for _, problem := range c.Environments[name].problems() {
			problems = append(problems, fmt.Sprintf("environments.%s.%s", name, problem))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("設定値に問題がある:\n  - %s", strings.Join(problems, "\n  - "))
	}
	return nil
}

func (e Environment) problems() []string {
	var problems []string
	check := func(field, value string, pattern *regexp.Regexp) {
		switch {
		case value == "":
			problems = append(problems, field+" が空")
		case !pattern.MatchString(value):
			problems = append(problems, fmt.Sprintf("%s の形式が不正: %q", field, value))
		}
	}
	positive := func(field string, value int) {
		if value <= 0 {
			problems = append(problems, field+" は 1 以上にする")
		}
	}

	check("aws_region", e.AWSRegion, regexp.MustCompile(`^[a-z]{2}(-[a-z]+)+-\d$`))
	check("application_name", e.ApplicationName, resourceNamePattern)
	check("release_instance_id", e.ReleaseInstanceID, instanceIDPattern)

	check("pipeline.stack_name", e.Pipeline.StackName, resourceNamePattern)
	check("pipeline.pipeline_name", e.Pipeline.PipelineName, resourceNamePattern)
	check("pipeline.codebuild_project_name", e.Pipeline.CodeBuildProjectName, resourceNamePattern)
	check("pipeline.codebuild_image", e.Pipeline.CodeBuildImage, codeBuildImagePattern)
	positive("pipeline.codebuild_timeout_minutes", e.Pipeline.CodeBuildTimeoutMinutes)
	check("pipeline.source_connection_arn", e.Pipeline.SourceConnectionARN, arnPattern)
	check("pipeline.source_repository_id", e.Pipeline.SourceRepositoryID, repositoryIDPattern)
	check("pipeline.source_branch_name", e.Pipeline.SourceBranchName, regexp.MustCompile(`^[A-Za-z0-9_./-]+$`))
	check("pipeline.log_group_name", e.Pipeline.LogGroupName, logGroupNamePattern)
	positive("pipeline.log_retention_days", e.Pipeline.LogRetentionDays)

	check("launch_template.stack_name", e.LaunchTemplate.StackName, resourceNamePattern)
	check("launch_template.launch_template_name", e.LaunchTemplate.LaunchTemplateName, resourceNamePattern)
	check("launch_template.instance_type", e.LaunchTemplate.InstanceType, regexp.MustCompile(`^[a-z0-9-]+\.[a-z0-9]+$`))
	if len(e.LaunchTemplate.SecurityGroupIDs) == 0 {
		problems = append(problems, "launch_template.security_group_ids が空")
	}
	for _, id := range e.LaunchTemplate.SecurityGroupIDs {
		check("launch_template.security_group_ids", id, securityGroupIDPattern)
	}
	for _, arn := range e.LaunchTemplate.SecretARNs {
		check("launch_template.secret_arns", arn, arnPattern)
	}
	if e.LaunchTemplate.UserDataFile != "" {
		check("launch_template.user_data_file", e.LaunchTemplate.UserDataFile, userDataFilePathPattern)
	}

	check("ssm_documents.stack_name", e.SSMDocuments.StackName, resourceNamePattern)
	check("ssm_documents.health_check_document_name", e.SSMDocuments.HealthCheckDocumentName, documentNamePattern)
	check("ssm_documents.health_check_url", e.SSMDocuments.HealthCheckURL, healthCheckURLPattern)

	positive("timeouts.image_available_seconds", e.Timeouts.ImageAvailableSeconds)
	positive("timeouts.instance_online_seconds", e.Timeouts.InstanceOnlineSeconds)
	if e.Timeouts.HealthCheckSeconds <= healthCheckCommandTimeoutSeconds {
		problems = append(problems, fmt.Sprintf(
			"timeouts.health_check_seconds は SSM ドキュメントの実行時間の上限（%d 秒）より長くする",
			healthCheckCommandTimeoutSeconds))
	}
	positive("timeouts.stack_update_seconds", e.Timeouts.StackUpdateSeconds)
	if e.Timeouts.PollIntervalSeconds < 0 {
		problems = append(problems, "timeouts.poll_interval_seconds は 0 以上にする")
	}
	return problems
}
