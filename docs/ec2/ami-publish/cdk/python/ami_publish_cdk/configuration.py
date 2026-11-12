"""設定値ファイル（config/ami_publish.yml）の読み込みと命名規則。

仕組みの生成ツール（Go の internal/definitions の configuration.go と naming.go）を写したもの。
命名規則・既定値・固定値を変えるときは、Go（生成ツールと CDK の Go 版はこれを共有）、Ruby（パイプラインの
スタック名だけ）と、ここを合わせて直す。

設定値の検証は、必要な項目があるかだけを確かめる。未知の項目や値の形式の検証は、仕組みの生成ツール
（go run ./cmd/generate-definitions --check）に任せる。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

# 仕組みの生成ツールと同じ固定値（Go の internal/definitions の定数）
BUILDSPEC_PATH = "generated/codebuild/ami-publish-buildspec.yml"
DEFAULT_CONFIG_PATH = "config/ami_publish.yml"
CONFIG_FILE_ENVIRONMENT_VARIABLE = "AMI_PUBLISH_CONFIG"
CODEBUILD_IMAGE = "aws/codebuild/standard:8.0"
HEALTH_CHECK_TIMEOUT_SECONDS = 240
SOURCE_TYPE_GITHUB = "github"
SOURCE_TYPE_CODECOMMIT = "codecommit"


class ConfigurationError(Exception):
    """設定値ファイルを読めない、または必要な項目がない。"""


@dataclass(frozen=True)
class PipelineSettings:
    source_type: str
    source_connection_arn: str
    source_repository_id: str
    source_repository_name: str
    source_branch_name: str
    log_retention_days: int


@dataclass(frozen=True)
class LaunchTemplateSettings:
    instance_type: str
    security_group_ids: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class HealthCheckSettings:
    url: str
    basic_auth_parameter_name: str


@dataclass(frozen=True)
class Environment:
    """1 環境分の設定値。リソースの名前は、下の命名規則で自動で決める。"""

    name: str
    aws_region: str
    application_name: str
    release_instance_id: str
    pipeline: PipelineSettings
    launch_template: LaunchTemplateSettings
    health_check: HealthCheckSettings
    codebuild_minutes: int

    # ── 命名規則（Go の naming.go と同じ）──

    @property
    def name_prefix(self) -> str:
        return f"{self.application_name}-{self.name}"

    @property
    def pipeline_stack_name(self) -> str:
        return f"{self.name_prefix}-ami-publish-pipeline"

    @property
    def pipeline_name(self) -> str:
        return f"{self.name_prefix}-ami-publish"

    @property
    def codebuild_project_name(self) -> str:
        return f"{self.name_prefix}-ami-publish"

    @property
    def log_group_name(self) -> str:
        return f"/{self.application_name}/{self.name}/ami-publish"

    @property
    def launch_template_stack_name(self) -> str:
        return f"{self.name_prefix}-launch-template"

    @property
    def launch_template_name(self) -> str:
        return self.name_prefix

    @property
    def health_check_stack_name(self) -> str:
        return f"{self.name_prefix}-health-check"

    @property
    def health_check_document_name(self) -> str:
        return f"{self.name_prefix}-health-check"

    @property
    def release_instance_stack_name(self) -> str:
        return f"{self.name_prefix}-release-instance"

    # Export の名前は「<スタック名>:<項目>」

    def launch_template_stack_export(self, item: str) -> str:
        return f"{self.launch_template_stack_name}:{item}"

    def health_check_stack_export(self, item: str) -> str:
        return f"{self.health_check_stack_name}:{item}"

    def release_instance_stack_export(self, item: str) -> str:
        return f"{self.release_instance_stack_name}:{item}"


@dataclass(frozen=True)
class Configuration:
    environments: list[Environment]


def load_configuration(path: str) -> Configuration:
    """設定値ファイルを読む。環境は名前順に並べる（生成順を固定するため）。"""
    try:
        document = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ConfigurationError(f"設定値ファイルを読めない: {error}") from error

    environments = (document or {}).get("environments") or {}
    if not environments:
        raise ConfigurationError(f"{path}: environments に環境が 1 つもない")
    return Configuration(
        environments=[_environment(name, environments[name] or {}) for name in sorted(environments)]
    )


def _environment(name: str, values: dict) -> Environment:
    def required(container: dict, key: str, label: str):
        value = container.get(key)
        if value is None or value == "" or value == []:
            raise ConfigurationError(f"environments.{name}.{label} を指定する")
        return value

    pipeline = values.get("pipeline") or {}
    launch_template = values.get("launch_template") or {}
    health_check = values.get("health_check") or {}
    timeouts = values.get("timeouts") or {}
    return Environment(
        name=name,
        aws_region=required(values, "aws_region", "aws_region"),
        application_name=required(values, "application_name", "application_name"),
        release_instance_id=required(values, "release_instance_id", "release_instance_id"),
        pipeline=PipelineSettings(
            source_type=pipeline.get("source_type") or SOURCE_TYPE_GITHUB,
            source_connection_arn=pipeline.get("source_connection_arn") or "",
            source_repository_id=pipeline.get("source_repository_id") or "",
            source_repository_name=pipeline.get("source_repository_name") or "",
            source_branch_name=required(pipeline, "source_branch_name", "pipeline.source_branch_name"),
            log_retention_days=int(required(pipeline, "log_retention_days", "pipeline.log_retention_days")),
        ),
        launch_template=LaunchTemplateSettings(
            instance_type=required(launch_template, "instance_type", "launch_template.instance_type"),
            security_group_ids=list(
                required(launch_template, "security_group_ids", "launch_template.security_group_ids")
            ),
        ),
        health_check=HealthCheckSettings(
            url=required(health_check, "url", "health_check.url"),
            basic_auth_parameter_name=health_check.get("basic_auth_parameter_name") or "",
        ),
        codebuild_minutes=int(required(timeouts, "codebuild_minutes", "timeouts.codebuild_minutes")),
    )
