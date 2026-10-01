# frozen_string_literal: true

require_relative "../../spec_helper"

# ヘルスチェックの区間だけ、リリース用インスタンスにインスタンスプロファイルを紐付ける。
RSpec.describe AmiPublish::Steps::WithReleaseInstanceProfile do
  let(:clients) { stub_clients }
  let(:calls) { [] }

  # 区間の中のステップの代わり。呼ばれたときの紐付けの有無を記録する。
  def recording_step(name, error: nil)
    ec2 = clients.ec2
    recorded = calls
    step_class = Class.new do
      define_method(:call) do |_context|
        associated = !ec2.describe_iam_instance_profile_associations.iam_instance_profile_associations.empty?
        recorded << [name, associated]
        raise error if error
      end
    end
    stub_const("AmiPublish::Steps::#{name}", step_class)
    step_class.new
  end

  def section(steps, **overrides)
    described_class.new(steps: steps, **step_dependencies(clients, **overrides))
  end

  def operations
    clients.ec2.api_requests.map { |request| request[:operation_name] }
  end

  it "紐付けてから区間の中のステップを実行し、終わったら解除する" do
    stub_profile_association_lifecycle(clients.ec2)

    section([recording_step("First"), recording_step("Second")]).call(context)

    expect(calls).to eq([["First", true], ["Second", true]])
    association = requests(clients.ec2, :associate_iam_instance_profile).first[:params]
    expect(association).to eq(instance_id: "i-0123456789abcdef0",
                              iam_instance_profile: { arn: SpecHelpers::PIPELINE_OUTPUTS["ReleaseInstanceProfileArn"] })
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).first[:params])
      .to eq(association_id: "iip-assoc-1")
    expect(log_events).to include("profile_associated", "profile_disassociated")
  end

  it "区間の中のステップが失敗しても解除し、元の失敗をそのまま返す" do
    stub_profile_association_lifecycle(clients.ec2)
    failure = AmiPublish::StepFailedError.new("ヘルスチェックが失敗した")
    steps = [recording_step("First", error: failure), recording_step("Second")]

    expect { section(steps).call(context) }.to raise_error(failure)

    expect(calls).to eq([["First", true]])
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).size).to eq(1)
  end

  it "このスタックのインスタンスプロファイルが残っていれば、紐付けずにそのまま使い、最後に解除する" do
    stub_profile_association_lifecycle(clients.ec2, associated: true)

    section([recording_step("First")]).call(context)

    expect(requests(clients.ec2, :associate_iam_instance_profile)).to be_empty
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).size).to eq(1)
    expect(log_events).to include("profile_association_reused")
  end

  it "成功した後に解除できなければ、AMI を残したまま失敗にする（手で外すコマンドを示す）" do
    stub_profile_association_lifecycle(clients.ec2)
    clients.ec2.stub_responses(:disassociate_iam_instance_profile, "UnauthorizedOperation")

    expect { section([recording_step("First")]).call(context(image_id: "ami-new")) }
      .to raise_error(AmiPublish::StepFailedError, /AMI は残している.*disassociate-iam-instance-profile/)
    expect(requests(clients.ec2, :deregister_image)).to be_empty
  end

  it "失敗した後に解除もできなければ、元の失敗を返し、解除の失敗はログに残す" do
    stub_profile_association_lifecycle(clients.ec2)
    clients.ec2.stub_responses(:disassociate_iam_instance_profile, "UnauthorizedOperation")
    failure = AmiPublish::StepFailedError.new("接続待ちのタイムアウト")

    expect { section([recording_step("First", error: failure)]).call(context) }.to raise_error(failure)
    expect(log_events).to include("profile_disassociate_failed")
  end

  it "紐付けが完了しなければ、区間の中のステップを実行せずに失敗にする（途中までの紐付けは解除する）" do
    clients.ec2.stub_responses(:associate_iam_instance_profile,
                               iam_instance_profile_association: profile_association(state: "associating"))
    # 開始時は紐付けなし。紐付けの後は associating のまま進まない
    clients.ec2.stub_responses(:describe_iam_instance_profile_associations, lambda { |request|
      associating = request.params[:association_ids] ? [profile_association(state: "associating")] : []
      { iam_instance_profile_associations: associating }
    })
    steps = [recording_step("First")]

    expect { section(steps, poller: expiring_poller).call(context) }
      .to raise_error(AmiPublish::StepFailedError, /紐付けられなかった。AMI は作成していない/)
    expect(calls).to be_empty
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).size).to eq(1)
  end

  it "dry-run では紐付けも解除もせず、予定をログに出す" do
    section([recording_step("First")]).call(context(dry_run: true))

    expect(calls).to eq([["First", false]])
    expect(operations).not_to include(:associate_iam_instance_profile, :disassociate_iam_instance_profile)
    expect(log_events).to include("profile_association_planned")
  end
end
