# frozen_string_literal: true

require_relative "../spec_helper"

# ヘルスチェックを省略する実行（--health-check false）では、SSM に依存する処理を一切行わない。
RSpec.describe "ヘルスチェックを省略する実行" do
  let(:clients) { stub_clients }
  let(:run_context) { context(image_id: "ami-1", instance_state_at_start: "stopped", health_check: false) }

  # ステップの開始・終了のログを除いたイベント
  def step_events
    log_events - %w[step_started step_finished]
  end

  it "health_check を指定しなければ、ヘルスチェックを行う（紐付けの予定が出る）" do
    step_with(AmiPublish::Steps::AttachReleaseInstanceProfile,
              **step_dependencies(clients)).call(context(dry_run: true))

    expect(step_events).to eq(%w[profile_association_planned])
  end

  it "停止中のインスタンスを起動せず、SSM の接続待ちとヘルスチェックも行わない" do
    [AmiPublish::Steps::StartInstanceIfStopped, AmiPublish::Steps::WaitInstanceOnline,
     AmiPublish::Steps::HealthCheck].each do |step_class|
      step_with(step_class, **step_dependencies(clients)).call(run_context)
    end

    expect(requests(clients.ec2, :start_instances)).to be_empty
    expect(requests(clients.ssm, :describe_instance_information)).to be_empty
    expect(requests(clients.ssm, :send_command)).to be_empty
    expect(step_events).to eq(%w[start_instance_skipped wait_instance_online_skipped health_check_skipped])
  end

  it "開始時のインスタンスプロファイルの紐付けの確認と、ロールの許可の確認も行わない" do
    clients.ec2.stub_responses(:describe_instances, reservations: [{ instances: [{
                                 instance_id: "i-0123456789abcdef0", state: { name: "running" }
                               }] }])

    step_with(AmiPublish::Steps::CheckInstanceState, **step_dependencies(clients)).call(run_context)
    step_with(AmiPublish::Steps::CheckReleaseInstancePermissions, **step_dependencies(clients)).call(run_context)

    expect(requests(clients.ec2, :describe_iam_instance_profile_associations)).to be_empty
    expect(requests(clients.iam, :simulate_principal_policy)).to be_empty
    expect(log_events).to include("profile_association_check_skipped", "release_instance_permissions_check_skipped")
  end

  it "インスタンスプロファイルの紐付けも解除も行わない" do
    [AmiPublish::Steps::AttachReleaseInstanceProfile,
     AmiPublish::Steps::DetachReleaseInstanceProfile].each do |step_class|
      step_with(step_class, **step_dependencies(clients)).call(run_context)
    end

    expect(clients.ec2.api_requests.map { |request| request[:operation_name] }).to be_empty
  end
end
