# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::FindPublishedImage do
  subject(:step) { step_with(described_class, **step_dependencies(clients)) }

  let(:clients) { stub_clients }

  it "戻し先のバージョンの公開済み AMI が 1 件なら、それを戻し先にする" do
    clients.ec2.stub_responses(:describe_images, images: [{ image_id: "ami-old", state: "available" }])
    run_context = context(version: "v1.2.2")

    step.call(run_context)

    expect(run_context.image_id).to eq("ami-old")
    filters = requests(clients.ec2, :describe_images).first[:params][:filters]
    expect(filters).to include({ name: "tag:AppVersion", values: ["v1.2.2"] },
                               { name: "tag:Status", values: ["published"] },
                               { name: "tag:Environment", values: ["staging"] })
  end

  it "見つからなければ失敗にする" do
    clients.ec2.stub_responses(:describe_images, images: [])

    expect { step.call(context(version: "v1.2.2")) }.to raise_error(AmiPublish::StepFailedError, /見つからない/)
  end

  it "複数あれば、どれに戻すか決められないので失敗にする" do
    clients.ec2.stub_responses(:describe_images, images: [{ image_id: "ami-a" }, { image_id: "ami-b" }])

    expect { step.call(context(version: "v1.2.2")) }.to raise_error(AmiPublish::StepFailedError, /ami-a, ami-b/)
  end
end
