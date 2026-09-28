# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AmiPublish::Configuration do
  # 名前は application_name と環境名から自動で決まる。Go の仕組み生成ツールのテスト
  # （internal/definitions/definitions_test.go の TestDerivedNames）も同じ名前を期待しており、
  # 両方で命名規則が一致していることを確かめる。
  it "リソースの名前を application_name と環境名から決める" do
    expect(configuration).to have_attributes(
      pipeline_stack_name: "myapp-staging-ami-publish-pipeline",
      log_group_name: "/myapp/staging/ami-publish",
      launch_template_stack_name: "myapp-staging-launch-template",
      health_check_document_name: "myapp-staging-health-check"
    )
  end

  it "application_name に大文字は使えない（名前に使うため）" do
    expect { configuration("application_name" => "MyApp") }
      .to raise_error(AmiPublish::ConfigurationError, /application_name の形式が不正/)
  end
end
