# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AmiPublish::Configuration do
  # 名前は application_name と環境名から自動で決まる。Go の仕組み生成ツールのテスト
  # （internal/definitions/definitions_test.go の TestDerivedNames）も同じ名前を期待しており、
  # 両方で命名規則が一致していることを確かめる。
  it "パイプラインのスタック名を application_name と環境名から決める（ほかの名前はスタックの出力から引く）" do
    expect(configuration.pipeline_stack_name).to eq("myapp-staging-ami-publish-pipeline")
  end

  it "application_name に大文字は使えない（名前に使うため）" do
    expect { configuration("application_name" => "MyApp") }
      .to raise_error(AmiPublish::ConfigurationError, /application_name の形式が不正/)
  end
end
