# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::CreateImage do
  subject(:step) { described_class.new(**step_dependencies(clients)) }

  let(:clients) { stub_clients }

  it "作成済みの AMI がなければ、タグを付けて AMI を作成する（再起動あり）" do
    clients.ec2.stub_responses(:describe_images, images: [])
    clients.ec2.stub_responses(:create_image, image_id: "ami-new")
    run_context = context

    step.call(run_context)

    expect(run_context.image_id).to eq("ami-new")
    params = requests(clients.ec2, :create_image).first[:params]
    expect(params[:instance_id]).to eq("i-0123456789abcdef0")
    expect(params[:no_reboot]).to be(false)
    expect(params[:tag_specifications].map { |spec| spec[:resource_type] }).to eq(%w[image snapshot])
    tags = params[:tag_specifications].first[:tags].to_h { |tag| [tag[:key], tag[:value]] }
    expect(tags["Name"]).to eq(params[:name])
    expect(params[:tag_specifications].last[:tags]).to include({ key: "Name", value: params[:name] })
    expect(tags).to include("App" => "myapp", "Environment" => "staging", "AppVersion" => "v1.2.3",
                            "Verified" => "manual", "PipelineExecutionId" => "exec-1", "Status" => "creating")
  end

  it "同じパイプライン実行で作成済みの AMI があれば、作らずに再利用する" do
    existing = { image_id: "ami-existing", state: "pending", creation_date: "2026-09-01T00:00:00.000Z" }
    clients.ec2.stub_responses(:describe_images, images: [existing])
    run_context = context

    step.call(run_context)

    expect(run_context.image_id).to eq("ami-existing")
    expect(requests(clients.ec2, :create_image)).to be_empty
    filters = requests(clients.ec2, :describe_images).first[:params][:filters]
    expect(filters).to include({ name: "tag:PipelineExecutionId", values: ["exec-1"] })
  end

  it "failed になった AMI は再利用せず、作り直す" do
    clients.ec2.stub_responses(:describe_images, images: [
                                 { image_id: "ami-failed", state: "failed", creation_date: "2026-09-01T00:00:00.000Z" }
                               ])
    clients.ec2.stub_responses(:create_image, image_id: "ami-new")
    run_context = context

    step.call(run_context)

    expect(run_context.image_id).to eq("ami-new")
  end

  it "dry-run では AMI を作成しない" do
    clients.ec2.stub_responses(:describe_images, images: [])
    run_context = context(dry_run: true)

    step.call(run_context)

    expect(run_context.image_id).to be_nil
    expect(requests(clients.ec2, :create_image)).to be_empty
    expect(log_events).to include("create_image_planned")
  end
end
