# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::HealthCheck do
  let(:clients) { stub_clients }

  before do
    clients.ssm.stub_responses(:send_command, command: { command_id: "cmd-1" })
    clients.ec2.stub_responses(:describe_images, images: [])
  end

  it "ヘルスチェックの SSM ドキュメントを実行し、成功すれば通す" do
    clients.ssm.stub_responses(:get_command_invocation, [
                                 "InvocationDoesNotExist",
                                 { status: "InProgress" },
                                 { status: "Success" }
                               ])
    step = described_class.new(**step_dependencies(clients))

    expect { step.call(context(image_id: "ami-1")) }.not_to raise_error

    params = requests(clients.ssm, :send_command).first[:params]
    expect(params[:document_name]).to eq("MyApp-Staging-HealthCheck")
    expect(params[:instance_ids]).to eq(["i-0123456789abcdef0"])
    expect(params[:cloud_watch_output_config]).to eq(cloud_watch_output_enabled: true,
                                                     cloud_watch_log_group_name: "/myapp/staging/ami-publish")
    expect(requests(clients.ec2, :deregister_image)).to be_empty
  end

  it "ヘルスチェックが失敗したら、AMI を削除して失敗にする" do
    clients.ssm.stub_responses(:get_command_invocation,
                               status: "Failed", standard_error_content: "health check failed: http://localhost/up")
    step = described_class.new(**step_dependencies(clients))

    expect { step.call(context(image_id: "ami-1")) }
      .to raise_error(AmiPublish::StepFailedError, %r{Failed.*http://localhost/up})
    expect(requests(clients.ec2, :deregister_image).first[:params]).to eq(image_id: "ami-1")
  end

  it "待機時間内に終わらなければ、AMI を削除して失敗にする" do
    clients.ssm.stub_responses(:get_command_invocation, status: "InProgress")
    step = described_class.new(**step_dependencies(clients, poller: expiring_poller))

    expect { step.call(context(image_id: "ami-1")) }.to raise_error(AmiPublish::StepFailedError, /ヘルスチェック/)
    expect(requests(clients.ec2, :deregister_image).size).to eq(1)
  end

  it "AMI を作成していない（dry-run）場合は実行しない" do
    described_class.new(**step_dependencies(clients)).call(context(image_id: nil))

    expect(requests(clients.ssm, :send_command)).to be_empty
  end
end
