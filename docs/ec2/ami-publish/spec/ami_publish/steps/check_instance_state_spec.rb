# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::CheckInstanceState do
  let(:clients) { stub_clients }

  def instance_state(name)
    { reservations: [{ instances: [{ instance_id: "i-0123456789abcdef0", state: { name: name } }] }] }
  end

  it "起動中で紐付けがなければ running を記録する" do
    clients.ec2.stub_responses(:describe_instances, instance_state("running"))
    run_context = context

    step_with(described_class, **step_dependencies(clients)).call(run_context)

    expect(run_context.instance_state_at_start).to eq("running")
  end

  it "停止処理中なら、停止するまで待ってから stopped を記録する" do
    clients.ec2.stub_responses(:describe_instances, [instance_state("stopping"), instance_state("stopped")])
    run_context = context

    step_with(described_class, **step_dependencies(clients)).call(run_context)

    expect(run_context.instance_state_at_start).to eq("stopped")
    expect(waiting_logs.first).to include("state" => "stopping")
  end

  it "終了済みなどの状態では、AWS を何も変更せずに失敗にする" do
    clients.ec2.stub_responses(:describe_instances, instance_state("terminated"))

    expect { step_with(described_class, **step_dependencies(clients)).call(context) }
      .to raise_error(AmiPublish::StepFailedError, /terminated/)
  end

  it "状態が落ち着かないまま待機時間を過ぎたら失敗にする" do
    clients.ec2.stub_responses(:describe_instances, instance_state("pending"))
    step = step_with(described_class, **step_dependencies(clients, poller: expiring_poller))

    expect { step.call(context) }.to raise_error(AmiPublish::StepFailedError, /pending/)
  end

  describe "インスタンスプロファイルの紐付けの確認（AMI を作る前に止める）" do
    before { clients.ec2.stub_responses(:describe_instances, instance_state("running")) }

    it "紐付けがなければ先に進む（SSM の管理対象かは確かめない）" do
      step_with(described_class, **step_dependencies(clients)).call(context)

      expect(log_events).to include("profile_association_checked")
      expect(requests(clients.ssm, :describe_instance_information)).to be_empty
    end

    it "このスタックのインスタンスプロファイルが残っていれば、そのまま先に進む（前回の異常終了の残り）" do
      clients.ec2.stub_responses(:describe_iam_instance_profile_associations,
                                 iam_instance_profile_associations: [profile_association])

      step_with(described_class, **step_dependencies(clients)).call(context)

      expect(log_events).to include("profile_association_left")
    end

    it "別のインスタンスプロファイルが付いていれば、入れ替えずに失敗にする" do
      clients.ec2.stub_responses(:describe_iam_instance_profile_associations, iam_instance_profile_associations: [
                                   profile_association(arn: "arn:aws:iam::123456789012:instance-profile/other")
                                 ])

      expect { step_with(described_class, **step_dependencies(clients)).call(context) }
        .to raise_error(AmiPublish::StepFailedError, %r{instance-profile/other.*AMI は作成していない})
    end

    it "解除済みの紐付けは数えない" do
      clients.ec2.stub_responses(:describe_iam_instance_profile_associations, iam_instance_profile_associations: [
                                   profile_association(arn: "arn:aws:iam::123456789012:instance-profile/other",
                                                       state: "disassociated")
                                 ])

      expect { step_with(described_class, **step_dependencies(clients)).call(context) }.not_to raise_error
    end
  end
end
