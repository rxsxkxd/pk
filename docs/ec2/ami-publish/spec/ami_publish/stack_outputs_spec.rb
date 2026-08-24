# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AmiPublish::StackOutputs do
  let(:clients) { stub_clients }
  let(:outputs) do
    described_class.new(cloudformation: clients.cloudformation, stack_name: "myapp-staging-ami-publish-pipeline")
  end

  it "パイプラインのスタックの出力を返す（取得は 1 回）" do
    clients.cloudformation.stub_responses(:describe_stacks, pipeline_stack_response)

    expect(outputs.fetch("LaunchTemplateStackName")).to eq("myapp-staging-launch-template")
    expect(outputs.fetch("LogGroupName")).to eq("/myapp/staging/ami-publish")
    expect(requests(clients.cloudformation, :describe_stacks).size).to eq(1)
  end

  it "出力がなければ、スタックが古い可能性を案内して失敗する" do
    clients.cloudformation.stub_responses(:describe_stacks, pipeline_stack_response({}))

    expect { outputs.fetch("LaunchTemplateStackName") }.to raise_error(AmiPublish::StepFailedError, /再デプロイ/)
  end

  it "スタックがなければ、命名規則どおりの名前でデプロイされているかを案内して失敗する" do
    clients.cloudformation.stub_responses(:describe_stacks, "ValidationError")

    expect { outputs.fetch("LogGroupName") }.to raise_error(AmiPublish::StepFailedError, /見つからない/)
  end
end
