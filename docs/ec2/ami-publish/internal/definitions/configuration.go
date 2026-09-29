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

// Environment は 1 環境分の設定値。リソースの名前は naming.go の命名規則で自動で決める。
type Environment struct {
	// Name は環境名（environments のキー）。読み込み時に設定する
	Name              string                 `yaml:"-"`
	AWSRegion         string                 `yaml:"aws_region"`
	ApplicationName   string                 `yaml:"application_name"`
	ReleaseInstanceID string                 `yaml:"release_instance_id"`
	Pipeline          PipelineSettings       `yaml:"pipeline"`
	LaunchTemplate    LaunchTemplateSettings `yaml:"launch_template"`
	HealthCheck       HealthCheckSettings    `yaml:"health_check"`
	Timeouts          TimeoutSettings        `yaml:"timeouts"`
}

// PipelineSettings は AMI 公開パイプラインのスタックの設定値。
type PipelineSettings struct {
	SourceConnectionARN string `yaml:"source_connection_arn"`
	SourceRepositoryID  string `yaml:"source_repository_id"`
	SourceBranchName    string `yaml:"source_branch_name"`
	LogRetentionDays    int    `yaml:"log_retention_days"`
}

// LaunchTemplateSettings は起動テンプレートのスタックの設定値。
type LaunchTemplateSettings struct {
	InstanceType     string   `yaml:"instance_type"`
	SecurityGroupIDs []string `yaml:"security_group_ids"`
}

// HealthCheckSettings は、再起動後のヘルスチェック（SSM ドキュメントとして登録する）のスタックの設定値。
type HealthCheckSettings struct {
	URL string `yaml:"url"`
	// BasicAuthParameterName は、Basic 認証の「ユーザー名:パスワード」を置いた SSM Parameter Store の
	// SecureString のパラメーター名（省略時は認証なし）
	BasicAuthParameterName string `yaml:"basic_auth_parameter_name"`
}

// TimeoutSettings は待機時間。CodeBuildMinutes は CodeBuild プロジェクトのタイムアウト（生成に使う）。
// それ以外は AMI 公開ツールの待機時間（秒）で、生成には使わないが、値の検証はここでも行う。
type TimeoutSettings struct {
	CodeBuildMinutes      int `yaml:"codebuild_minutes"`
	ImageAvailableSeconds int `yaml:"image_available_seconds"`
	InstanceOnlineSeconds int `yaml:"instance_online_seconds"`
	HealthCheckSeconds    int `yaml:"health_check_seconds"`
	StackUpdateSeconds    int `yaml:"stack_update_seconds"`
	PollIntervalSeconds   int `yaml:"poll_interval_seconds"`
	// ProgressLogIntervalSeconds は、待っている間に進捗をログに出す間隔
	ProgressLogIntervalSeconds int `yaml:"progress_log_interval_seconds"`
}

// 自動で決める名前のうち最も長い「<アプリ>-<環境>-ami-publish-pipeline」などを、各サービスの名前の上限に収めるための上限。
const maxNamePrefixLength = 60

var (
	environmentNamePattern = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	applicationNamePattern = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	instanceIDPattern      = regexp.MustCompile(`^i-[0-9a-f]{8,17}$`)
	securityGroupIDPattern = regexp.MustCompile(`^sg-[0-9a-f]{8,17}$`)
	healthCheckURLPattern  = regexp.MustCompile(`^https?://[A-Za-z0-9._:/-]+$`)
	parameterNamePattern   = regexp.MustCompile(`^/[A-Za-z0-9_./-]+$`)
	repositoryIDPattern    = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
	arnPattern             = regexp.MustCompile(`^arn:aws[a-z-]*:[a-z0-9-]+:`)
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
	for name, environment := range configuration.Environments {
		environment.Name = name
		configuration.Environments[name] = environment
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
	// 名前はアプリケーション名から自動で決めるため、ロググループや SSM ドキュメントの名前にも使える文字に限る
	check("application_name", e.ApplicationName, applicationNamePattern)
	if strings.HasPrefix(e.ApplicationName, "aws") || strings.HasPrefix(e.ApplicationName, "amazon") {
		problems = append(problems, "application_name は aws / amazon で始めない（SSM ドキュメントの名前に使えないため）")
	}
	if length := len(e.ApplicationName) + len(e.Name); length > maxNamePrefixLength {
		problems = append(problems, fmt.Sprintf(
			"application_name と環境名の長さの合計は %d 文字以下にする（%d 文字）", maxNamePrefixLength, length))
	}
	check("release_instance_id", e.ReleaseInstanceID, instanceIDPattern)

	check("pipeline.source_connection_arn", e.Pipeline.SourceConnectionARN, arnPattern)
	check("pipeline.source_repository_id", e.Pipeline.SourceRepositoryID, repositoryIDPattern)
	check("pipeline.source_branch_name", e.Pipeline.SourceBranchName, regexp.MustCompile(`^[A-Za-z0-9_./-]+$`))
	positive("pipeline.log_retention_days", e.Pipeline.LogRetentionDays)

	check("launch_template.instance_type", e.LaunchTemplate.InstanceType, regexp.MustCompile(`^[a-z0-9-]+\.[a-z0-9]+$`))
	if len(e.LaunchTemplate.SecurityGroupIDs) == 0 {
		problems = append(problems, "launch_template.security_group_ids が空")
	}
	for _, id := range e.LaunchTemplate.SecurityGroupIDs {
		check("launch_template.security_group_ids", id, securityGroupIDPattern)
	}

	check("health_check.url", e.HealthCheck.URL, healthCheckURLPattern)
	if e.HealthCheck.BasicAuthParameterName != "" {
		check("health_check.basic_auth_parameter_name", e.HealthCheck.BasicAuthParameterName, parameterNamePattern)
		if len(e.HealthCheck.BasicAuthParameterName) > 1011 {
			problems = append(problems, "health_check.basic_auth_parameter_name は 1011 文字以下にする")
		}
	}

	positive("timeouts.codebuild_minutes", e.Timeouts.CodeBuildMinutes)
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
	if e.Timeouts.ProgressLogIntervalSeconds < 0 {
		problems = append(problems, "timeouts.progress_log_interval_seconds は 0 以上にする")
	}
	return problems
}
