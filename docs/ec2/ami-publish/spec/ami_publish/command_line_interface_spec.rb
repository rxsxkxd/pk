# frozen_string_literal: true

require "tmpdir"
require_relative "../spec_helper"

RSpec.describe AmiPublish::CommandLineInterface do
  let(:clients) { stub_clients }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  around do |example|
    Dir.mktmpdir do |directory|
      @config_path = File.join(directory, "ami_publish.yml")
      File.write(@config_path, YAML.dump("environments" => { "staging" => SpecHelpers::SETTINGS }))
      example.run
    end
  end

  def run_cli(*arguments)
    described_class.new([*arguments, "--config", @config_path],
                        stdout: stdout, stderr: stderr, client_factory: ->(_) { clients }).run
  end

  def stub_launch_template_stack
    clients.cloudformation.stub_responses(:describe_stacks, stacks: [{
                                            stack_name: "myapp-staging-launch-template", creation_time: Time.now,
                                            stack_status: "UPDATE_COMPLETE",
                                            parameters: [{ parameter_key: "AmiId", parameter_value: "ami-old" },
                                                         { parameter_key: "AppVersion", parameter_value: "v1.2.2" }],
                                            outputs: [{ output_key: "LaunchTemplateVersion", output_value: "3" }]
                                          }])
  end

  describe "使い方の誤り（終了コード 2）" do
    it "サブコマンドがない" do
      expect(run_cli).to eq(2)
      expect(stderr.string).to include("使い方")
    end

    it "--version がない" do
      expect(run_cli("run", "--environment", "staging")).to eq(2)
      expect(stderr.string).to include("--version を指定する")
    end

    it "--version の形式が不正" do
      expect(run_cli("run", "--environment", "staging", "--version", "1.2.3")).to eq(2)
    end

    it "--verified が manual / automated 以外" do
      expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3", "--verified", "yes")).to eq(2)
    end

    it "設定値ファイルにない環境" do
      expect(run_cli("run", "--environment", "production", "--version", "v1.2.3")).to eq(2)
      expect(stderr.string).to include("環境 production")
    end

    it "rollback に --version を指定した" do
      expect(run_cli("rollback", "--environment", "staging", "--version", "v1.2.2")).to eq(2)
    end
  end

  it "plan は AWS に書き込まずに成功する" do
    clients.ec2.stub_responses(:describe_images, images: [])
    stub_launch_template_stack

    expect(run_cli("plan", "--environment", "staging", "--version", "v1.2.3")).to eq(0)
    expect(requests(clients.ec2, :create_image)).to be_empty
    expect(requests(clients.cloudformation, :create_change_set)).to be_empty
    expect(requests(clients.ssm, :send_command)).to be_empty
  end

  it "run で AMI の作成に失敗したら終了コード 1 を返し、起動テンプレートのスタックは更新しない" do
    clients.ec2.stub_responses(:describe_images, [
                                 { images: [] },
                                 { images: [{ image_id: "ami-new", state: "failed" }] }
                               ])
    clients.ec2.stub_responses(:create_image, image_id: "ami-new")

    expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3")).to eq(1)
    expect(requests(clients.cloudformation, :create_change_set)).to be_empty
    expect(requests(clients.ec2, :deregister_image).size).to eq(1)
  end

  it "想定外の AWS エラーは終了コード 3 を返す" do
    clients.ec2.stub_responses(:describe_images, "UnauthorizedOperation")

    expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3")).to eq(3)
  end

  it "AWS に接続できない場合も終了コード 3 を返す" do
    clients.ec2.stub_responses(:describe_images, Seahorse::Client::NetworkingError.new(StandardError.new("down")))

    expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3")).to eq(3)
  end
end
