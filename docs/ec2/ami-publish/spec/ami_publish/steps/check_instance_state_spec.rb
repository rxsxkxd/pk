# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::CheckInstanceState do
  let(:clients) { stub_clients }

  def instance_state(name)
    { reservations: [{ instances: [{ instance_id: "i-0123456789abcdef0", state: { name: name } }] }] }
  end

  def ssm(ping_status)
    list = ping_status ? [{ instance_id: "i-0123456789abcdef0", ping_status: ping_status }] : []
    { instance_information_list: list }
  end

  it "起動中で SSM Agent が接続していれば running を記録する" do
    clients.ec2.stub_responses(:describe_instances, instance_state("running"))
    clients.ssm.stub_responses(:describe_instance_information, ssm("Online"))
    run_context = context

    described_class.new(**step_dependencies(clients)).call(run_context)

    expect(run_context.instance_state_at_start).to eq("running")
  end

  it "停止処理中なら、停止するまで待ってから stopped を記録する" do
    clients.ec2.stub_responses(:describe_instances, [instance_state("stopping"), instance_state("stopped")])
    clients.ssm.stub_responses(:describe_instance_information, ssm("ConnectionLost"))
    run_context = context

    described_class.new(**step_dependencies(clients)).call(run_context)

    expect(run_context.instance_state_at_start).to eq("stopped")
    expect(waiting_logs.first).to include("state" => "stopping")
  end

  it "終了済みなどの状態では、AWS を何も変更せずに失敗にする" do
    clients.ec2.stub_responses(:describe_instances, instance_state("terminated"))

    expect { described_class.new(**step_dependencies(clients)).call(context) }
      .to raise_error(AmiPublish::StepFailedError, /terminated/)
  end

  it "状態が落ち着かないまま待機時間を過ぎたら失敗にする" do
    clients.ec2.stub_responses(:describe_instances, instance_state("pending"))
    step = described_class.new(**step_dependencies(clients, poller: expiring_poller))

    expect { step.call(context) }.to raise_error(AmiPublish::StepFailedError, /pending/)
  end

  describe "SSM の管理対象かの確認（AMI を作る前に止める）" do
    it "起動中で SSM Agent がまだ接続していなければ、接続するまで待つ" do
      clients.ec2.stub_responses(:describe_instances, instance_state("running"))
      clients.ssm.stub_responses(:describe_instance_information, [ssm("ConnectionLost"), ssm("Online")])
      run_context = context

      described_class.new(**step_dependencies(clients)).call(run_context)

      expect(run_context.instance_state_at_start).to eq("running")
      expect(waiting_logs.first).to include("ping_status" => "ConnectionLost")
    end

    it "起動中で SSM の管理対象になっていなければ、待機時間の後に失敗にする" do
      clients.ec2.stub_responses(:describe_instances, instance_state("running"))
      clients.ssm.stub_responses(:describe_instance_information, ssm(nil))
      step = described_class.new(**step_dependencies(clients, poller: expiring_poller))

      expect { step.call(context) }.to raise_error(AmiPublish::StepFailedError, /SSM の管理対象になっていない/)
    end

    it "停止中で SSM の管理対象になっていなければ、待たずに失敗にする" do
      clients.ec2.stub_responses(:describe_instances, instance_state("stopped"))
      clients.ssm.stub_responses(:describe_instance_information, ssm(nil))

      expect { described_class.new(**step_dependencies(clients)).call(context) }
        .to raise_error(AmiPublish::StepFailedError, /AMI は作成していない/)
      expect(requests(clients.ssm, :describe_instance_information).size).to eq(1)
    end
  end
end
