# frozen_string_literal: true

require_relative "../spec_helper"

# ヘルスチェックを省略する実行（--health-check false）では、SSM に依存する処理を一切行わない。
RSpec.describe "ヘルスチェックを省略する実行" do
  let(:clients) { stub_clients }
  let(:run_context) { context(image_id: "ami-1", instance_state_at_start: "stopped", health_check: false) }

  it "既定ではヘルスチェックを行う" do
    expect(context.health_check?).to be(true)
  end

  it "停止中のインスタンスを起動せず、SSM の接続待ちとヘルスチェックも行わない" do
    [AmiPublish::Steps::StartInstanceIfStopped, AmiPublish::Steps::WaitInstanceOnline,
     AmiPublish::Steps::HealthCheck].each do |step_class|
      step_class.new(**step_dependencies(clients)).call(run_context)
    end

    expect(requests(clients.ec2, :start_instances)).to be_empty
    expect(requests(clients.ssm, :describe_instance_information)).to be_empty
    expect(requests(clients.ssm, :send_command)).to be_empty
    expect(log_events).to eq(%w[start_instance_skipped wait_instance_online_skipped health_check_skipped])
  end

  it "開始時の SSM の管理対象の確認と、ロールの許可の確認も行わない" do
    clients.ec2.stub_responses(:describe_instances, reservations: [{ instances: [{
                                 instance_id: "i-0123456789abcdef0", state: { name: "running" }
                               }] }])

    AmiPublish::Steps::CheckInstanceState.new(**step_dependencies(clients)).call(run_context)
    AmiPublish::Steps::CheckReleaseInstancePermissions.new(**step_dependencies(clients)).call(run_context)

    expect(requests(clients.ssm, :describe_instance_information)).to be_empty
    expect(requests(clients.iam, :simulate_principal_policy)).to be_empty
    expect(log_events).to include("ssm_check_skipped", "release_instance_permissions_check_skipped")
  end
end
