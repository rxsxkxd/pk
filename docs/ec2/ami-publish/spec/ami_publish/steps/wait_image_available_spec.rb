# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::WaitImageAvailable do
  subject(:step) { described_class.new(**step_dependencies(clients)) }

  let(:clients) { stub_clients }

  it "AMI が available になれば成功する" do
    clients.ec2.stub_responses(:describe_images, images: [{ image_id: "ami-1", state: "available" }])

    expect { step.call(context(image_id: "ami-1")) }.not_to raise_error
    expect(requests(clients.ec2, :deregister_image)).to be_empty
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
