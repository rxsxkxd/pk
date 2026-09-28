# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::StartInstanceIfStopped do
  subject(:step) { described_class.new(**step_dependencies(clients)) }

  let(:clients) { stub_clients }

  def instance_state(name)
    { reservations: [{ instances: [{ instance_id: "i-0123456789abcdef0", state: { name: name } }] }] }
  end

  it "開始時に起動中だった場合は何もしない" do
    step.call(context(image_id: "ami-1", instance_state_at_start: "running"))

    expect(requests(clients.ec2, :start_instances)).to be_empty
  end

  it "開始時に停止中だった場合は、インスタンスを起動して running になるまで待つ（停止には戻さない）" do
    clients.ec2.stub_responses(:describe_instances, [instance_state("pending"), instance_state("running")])

    step.call(context(image_id: "ami-1", instance_state_at_start: "stopped"))

    expect(requests(clients.ec2, :start_instances).first[:params]).to eq(instance_ids: ["i-0123456789abcdef0"])
    expect(requests(clients.ec2, :stop_instances)).to be_empty
    expect(waiting_logs.first).to include("description" => "リリース用インスタンスの起動", "state" => "pending")
  end

  it "起動できなかったら、確認できない AMI として削除して失敗にする" do
    clients.ec2.stub_responses(:start_instances, "InsufficientInstanceCapacity")
    clients.ec2.stub_responses(:describe_images, images: [])

    expect { step.call(context(image_id: "ami-1", instance_state_at_start: "stopped")) }
      .to raise_error(AmiPublish::StepFailedError, /起動できなかった/)
    expect(requests(clients.ec2, :deregister_image).first[:params]).to eq(image_id: "ami-1")
  end

  it "dry-run（AMI を作成していない）では起動しない" do
    step.call(context(image_id: nil, instance_state_at_start: "stopped"))

    expect(requests(clients.ec2, :start_instances)).to be_empty
    expect(log_events).to include("start_instance_planned")
  end
end
