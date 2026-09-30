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

  def stub_instance_state(name)
    clients.ec2.stub_responses(:describe_instances, reservations: [{ instances: [{
                                 instance_id: "i-0123456789abcdef0", state: { name: name },
                                 iam_instance_profile: { arn: "arn:aws:iam::123456789012:instance-profile/release" }
                               }] }])
    stub_release_instance_role
    stub_launch_template_stack
    ping_status = name == "running" ? "Online" : "ConnectionLost"
    clients.ssm.stub_responses(:describe_instance_information, instance_information_list: [{
                                 instance_id: "i-0123456789abcdef0", ping_status: ping_status
                               }])
  end

  # リリース用インスタンスのロールと、許可がすべてある判定結果
  def stub_release_instance_role
    clients.iam.stub_responses(:get_instance_profile, instance_profile: {
                                 path: "/", instance_profile_name: "release", instance_profile_id: "id",
                                 arn: "arn:aws:iam::123456789012:instance-profile/release", create_date: Time.now,
                                 roles: [{ path: "/", role_name: "release", role_id: "id", create_date: Time.now,
                                           arn: "arn:aws:iam::123456789012:role/release" }]
                               })
    clients.iam.stub_responses(:simulate_principal_policy, lambda { |request|
      { is_truncated: false, evaluation_results: request.params[:action_names].map do |action|
        { eval_action_name: action, eval_decision: "allowed" }
      end }
    })
  end

  # パイプラインのスタック（出力で他のスタックの名前を返す）と、起動テンプレートのスタック
  def stub_launch_template_stack
    launch_template_stack = {
      stack_name: "myapp-staging-launch-template", creation_time: Time.now, stack_status: "UPDATE_COMPLETE",
      parameters: [{ parameter_key: "AmiId", parameter_value: "ami-old" },
                   { parameter_key: "AppVersion", parameter_value: "v1.2.2" }],
      outputs: [{ output_key: "LaunchTemplateVersion", output_value: "3" }]
    }
    clients.cloudformation.stub_responses(:describe_stacks, lambda { |request|
      if request.params[:stack_name] == "myapp-staging-ami-publish-pipeline"
        pipeline_stack_response
      else
        { stacks: [launch_template_stack] }
      end
    })
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

    it "--health-check が true / false 以外" do
      expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3", "--health-check", "no")).to eq(2)
    end

    it "rollback に --version を指定した" do
      expect(run_cli("rollback", "--environment", "staging", "--version", "v1.2.2")).to eq(2)
    end
  end

  it "plan は AWS に書き込まずに成功する" do
    stub_instance_state("running")
    clients.ec2.stub_responses(:describe_images, images: [])
    stub_launch_template_stack

    expect(run_cli("plan", "--environment", "staging", "--version", "v1.2.3")).to eq(0)
    expect(requests(clients.ec2, :create_image)).to be_empty
    expect(requests(clients.cloudformation, :create_change_set)).to be_empty
    expect(requests(clients.ssm, :send_command)).to be_empty
  end

  it "plan で停止中のインスタンスは、起動もしない" do
    stub_instance_state("stopped")
    clients.ec2.stub_responses(:describe_images, images: [])
    stub_launch_template_stack

    expect(run_cli("plan", "--environment", "staging", "--version", "v1.2.3")).to eq(0)
    expect(requests(clients.ec2, :start_instances)).to be_empty
    expect(stdout.string).to include('"event":"start_instance_planned"')
  end

  it "run で AMI の作成に失敗したら終了コード 1 を返し、起動テンプレートのスタックは更新しない" do
    stub_instance_state("running")
    clients.ec2.stub_responses(:describe_images, [
                                 { images: [] },
                                 { images: [{ image_id: "ami-new", state: "failed" }] }
                               ])
    clients.ec2.stub_responses(:create_image, image_id: "ami-new")

    expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3")).to eq(1)
    expect(requests(clients.cloudformation, :create_change_set)).to be_empty
    expect(requests(clients.ec2, :deregister_image).size).to eq(1)
  end

  it "SSM の管理対象でないインスタンスは、AMI を作らずに終了コード 1 を返す" do
    clients.ec2.stub_responses(:describe_instances, reservations: [{ instances: [{
                                 instance_id: "i-0123456789abcdef0", state: { name: "stopped" }
                               }] }])
    clients.ssm.stub_responses(:describe_instance_information, instance_information_list: [])

    expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3")).to eq(1)
    expect(requests(clients.ec2, :create_image)).to be_empty
  end

  it "想定外の AWS エラーは終了コード 3 を返す" do
    clients.ec2.stub_responses(:describe_instances, "UnauthorizedOperation")

    expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3")).to eq(3)
  end

  it "AWS に接続できない場合も終了コード 3 を返す" do
    clients.ec2.stub_responses(:describe_instances,
                               Seahorse::Client::NetworkingError.new(StandardError.new("down")))

    expect(run_cli("run", "--environment", "staging", "--version", "v1.2.3")).to eq(3)
  end
end
