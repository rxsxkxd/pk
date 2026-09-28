# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::CheckInstanceState do
  let(:clients) { stub_clients }

  def instance_state(name)
    { reservations: [{ instances: [{ instance_id: "i-0123456789abcdef0", state: { name: name } }] }] }
  end

  it "起動中なら running を記録する" do
    clients.ec2.stub_responses(:describe_instances, instance_state("running"))
    run_context = context

    described_class.new(**step_dependencies(clients)).call(run_context)

    expect(run_context.instance_state_at_start).to eq("running")
  end

  it "停止処理中なら、停止するまで待ってから stopped を記録する" do
    clients.ec2.stub_responses(:describe_instances, [instance_state("stopping"), instance_state("stopped")])
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
end
