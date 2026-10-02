# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::WaitImageAvailable do
  subject(:step) { step_with(described_class, **step_dependencies(clients)) }

  let(:clients) { stub_clients }

  it "AMI が available になれば成功する" do
    clients.ec2.stub_responses(:describe_images, images: [{ image_id: "ami-1", state: "available" }])

    expect { step.call(context(image_id: "ami-1")) }.not_to raise_error
    expect(requests(clients.ec2, :deregister_image)).to be_empty
  end

  it "待っている間は、AMI の状態とスナップショットの進み具合を進捗として出す" do
    mapping = { device_name: "/dev/xvda", ebs: { snapshot_id: "snap-1" } }
    pending = { image_id: "ami-1", state: "pending", block_device_mappings: [mapping] }
    clients.ec2.stub_responses(:describe_images, [{ images: [pending] },
                                                  { images: [{ image_id: "ami-1", state: "available" }] }])
    clients.ec2.stub_responses(:describe_snapshots, snapshots: [{ snapshot_id: "snap-1", progress: "45%" }])

    step.call(context(image_id: "ami-1"))

    expect(waiting_logs.first).to include("description" => "AMI の作成（スナップショットの取得）",
                                          "image_id" => "ami-1", "state" => "pending",
                                          "snapshots" => ["snap-1 45%"])
  end

  it "AMI が failed になったら、AMI とスナップショットを削除して失敗にする" do
    mapping = { device_name: "/dev/xvda", ebs: { snapshot_id: "snap-1" } }
    clients.ec2.stub_responses(:describe_images,
                               images: [{ image_id: "ami-1", state: "failed", block_device_mappings: [mapping] }])

    expect { step.call(context(image_id: "ami-1")) }.to raise_error(AmiPublish::StepFailedError, /available/)
    expect(requests(clients.ec2, :deregister_image).first[:params]).to eq(image_id: "ami-1")
    expect(requests(clients.ec2, :delete_snapshot).first[:params]).to eq(snapshot_id: "snap-1")
  end

  it "AMI を作成していない（dry-run）場合は何もしない" do
    step.call(context(image_id: nil))

    expect(requests(clients.ec2, :describe_images)).to be_empty
  end
end
