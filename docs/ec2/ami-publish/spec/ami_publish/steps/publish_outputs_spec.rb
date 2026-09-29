# frozen_string_literal: true

require "tmpdir"
require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::PublishOutputs do
  let(:clients) { stub_clients }

  around do |example|
    Dir.mktmpdir do |directory|
      @output_path = File.join(directory, "ami_publish_outputs.env")
      example.run
    end
  end

  attr_reader :output_path

  it "AMI に Status=published と HealthCheck=passed を付け、出力値をファイルに書き出す" do
    step = described_class.new(output_env_file: output_path, **step_dependencies(clients))

    step.call(context(image_id: "ami-new", launch_template_version: "4"))

    expect(requests(clients.ec2, :create_tags).first[:params])
      .to eq(resources: ["ami-new"], tags: [{ key: "Status", value: "published" },
                                            { key: "HealthCheck", value: "passed" }])
    expect(File.read(output_path)).to eq("AMI_ID=ami-new\nLAUNCH_TEMPLATE_VERSION=4\n")
  end

  it "ヘルスチェックを省略した実行では HealthCheck=skipped を付ける" do
    step = described_class.new(**step_dependencies(clients))

    step.call(context(image_id: "ami-new", launch_template_version: "4", health_check: false))

    expect(requests(clients.ec2, :create_tags).first[:params][:tags])
      .to include({ key: "HealthCheck", value: "skipped" })
  end

  it "tag_image: false（rollback）ではタグを変えない" do
    step = described_class.new(output_env_file: output_path, tag_image: false, **step_dependencies(clients))

    step.call(context(image_id: "ami-old", launch_template_version: "5"))

    expect(requests(clients.ec2, :create_tags)).to be_empty
    expect(File.read(output_path)).to include("AMI_ID=ami-old")
  end

  it "シェルで読み込めない値は書き出さずに失敗にする" do
    step = described_class.new(output_env_file: output_path, tag_image: false, **step_dependencies(clients))

    expect { step.call(context(image_id: "ami-1; rm -rf /", launch_template_version: "4")) }
      .to raise_error(AmiPublish::StepFailedError)
    expect(File.exist?(output_path)).to be(false)
  end

  it "dry-run では何も変更しない" do
    step = described_class.new(output_env_file: output_path, **step_dependencies(clients))

    step.call(context(image_id: nil, dry_run: true))

    expect(requests(clients.ec2, :create_tags)).to be_empty
    expect(File.exist?(output_path)).to be(false)
  end
end
