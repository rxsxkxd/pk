# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::WaitInstanceOnline do
  let(:clients) { stub_clients }

  it "SSM Agent が Online になるまで確認を繰り返す" do
    clients.ssm.stub_responses(:describe_instance_information, [
                                 { instance_information_list: [] },
                                 { instance_information_list: [{ instance_id: "i-0123456789abcdef0",
                                                                 ping_status: "ConnectionLost" }] },
                                 { instance_information_list: [{ instance_id: "i-0123456789abcdef0",
                                                                 ping_status: "Online" }] }
                               ])
    step = described_class.new(**step_dependencies(clients))

    expect { step.call(context(image_id: "ami-1")) }.not_to raise_error
    expect(requests(clients.ssm, :describe_instance_information).size).to eq(3)
  end

  it "待機時間内に Online にならなければ、AMI を削除して失敗にする" do
    clients.ssm.stub_responses(:describe_instance_information,
                               instance_information_list: [{ instance_id: "i-0123456789abcdef0",
                                                             ping_status: "ConnectionLost" }])
    clients.ec2.stub_responses(:describe_images, images: [])
    step = described_class.new(**step_dependencies(clients, poller: expiring_poller))

    expect { step.call(context(image_id: "ami-1")) }.to raise_error(AmiPublish::StepFailedError, /SSM Agent/)
    expect(requests(clients.ec2, :deregister_image).first[:params]).to eq(image_id: "ami-1")
  end
end
