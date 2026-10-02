# frozen_string_literal: true

require_relative "../../spec_helper"

# ヘルスチェックの区間だけ、リリース用インスタンスにインスタンスプロファイルを紐付ける。
# 紐付け（AttachReleaseInstanceProfile）と解除（DetachReleaseInstanceProfile）の間にステップを並べた
# Organizer で、成功時・失敗時の解除を確かめる（失敗時の解除は interactor が呼ぶ rollback）。
RSpec.describe "リリース用インスタンスへのインスタンスプロファイルの紐付けと解除" do
  let(:clients) { stub_clients }
  let(:calls) { [] }

  # 区間の中のステップの代わり。呼ばれたときの紐付けの有無を記録する。
  def recording_step(name, error: nil)
    recorded = calls
    step_class = Class.new(AmiPublish::Steps::BaseStep) do
      define_method(:call) do
        associated = !clients.ec2.describe_iam_instance_profile_associations.iam_instance_profile_associations.empty?
        recorded << [name, associated]
        raise error if error
      end
    end
    stub_const("AmiPublish::Steps::#{name}", step_class)
  end

  # 紐付け → 区間の中のステップ → 解除（→ 後続のステップ）の Organizer を実行する
  def run_section(inner, after: [], **values)
    steps = [AmiPublish::Steps::AttachReleaseInstanceProfile, *inner,
             AmiPublish::Steps::DetachReleaseInstanceProfile, *after]
    organizer = Class.new do
      include Interactor::Organizer

      organize(*steps)
    end
    organizer.call!(**step_dependencies(clients), version: "v1.2.3", dry_run: false, **values)
  end

  def operations
    clients.ec2.api_requests.map { |request| request[:operation_name] }
  end

  it "紐付けてから区間の中のステップを実行し、終わったら解除する" do
    stub_profile_association_lifecycle(clients.ec2)

    run_section([recording_step("First"), recording_step("Second")])

    expect(calls).to eq([["First", true], ["Second", true]])
    association = requests(clients.ec2, :associate_iam_instance_profile).first[:params]
    expect(association).to eq(instance_id: "i-0123456789abcdef0",
                              iam_instance_profile: { arn: SpecHelpers::PIPELINE_OUTPUTS["ReleaseInstanceProfileArn"] })
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).first[:params])
      .to eq(association_id: "iip-assoc-1")
    expect(log_events).to include("profile_associated", "profile_disassociated")
  end

  it "区間の中のステップが失敗しても解除し（rollback）、元の失敗をそのまま返す" do
    stub_profile_association_lifecycle(clients.ec2)
    failure = AmiPublish::StepFailedError.new("ヘルスチェックが失敗した")

    expect { run_section([recording_step("First", error: failure), recording_step("Second")]) }
      .to raise_error(failure)

    expect(calls).to eq([["First", true]])
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).size).to eq(1)
  end

  it "解除の後のステップが失敗しても、解除し直さない（紐付けは解除済み）" do
    stub_profile_association_lifecycle(clients.ec2)
    failure = AmiPublish::StepFailedError.new("スタックの更新が失敗した")

    expect { run_section([recording_step("First")], after: [recording_step("Update", error: failure)]) }
      .to raise_error(failure)

    expect(requests(clients.ec2, :disassociate_iam_instance_profile).size).to eq(1)
  end

  it "このスタックのインスタンスプロファイルが残っていれば、紐付けずにそのまま使い、最後に解除する" do
    stub_profile_association_lifecycle(clients.ec2, associated: true)

    run_section([recording_step("First")])

    expect(requests(clients.ec2, :associate_iam_instance_profile)).to be_empty
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).size).to eq(1)
    expect(log_events).to include("profile_association_reused")
  end

  it "成功した後に解除できなければ、AMI を残したまま失敗にする（手で外すコマンドを示す）" do
    stub_profile_association_lifecycle(clients.ec2)
    clients.ec2.stub_responses(:disassociate_iam_instance_profile, "UnauthorizedOperation")

    expect { run_section([recording_step("First")], image_id: "ami-new") }
      .to raise_error(AmiPublish::StepFailedError, /AMI は残している.*disassociate-iam-instance-profile/)
    expect(requests(clients.ec2, :deregister_image)).to be_empty
    expect(log_events).to include("profile_disassociate_failed") # rollback でもう一度試みた結果
  end

  it "失敗した後に解除もできなければ、元の失敗を返し、解除の失敗はログに残す" do
    stub_profile_association_lifecycle(clients.ec2)
    clients.ec2.stub_responses(:disassociate_iam_instance_profile, "UnauthorizedOperation")
    failure = AmiPublish::StepFailedError.new("接続待ちのタイムアウト")

    expect { run_section([recording_step("First", error: failure)]) }.to raise_error(failure)
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

    expect { run_section([recording_step("First")], poller: expiring_poller) }
      .to raise_error(AmiPublish::StepFailedError, /紐付けられなかった。AMI は作成していない/)
    expect(calls).to be_empty
    expect(requests(clients.ec2, :disassociate_iam_instance_profile).size).to eq(1)
  end

  it "dry-run では紐付けも解除もせず、予定をログに出す" do
    run_section([recording_step("First")], dry_run: true)

    expect(calls).to eq([["First", false]])
    expect(operations).not_to include(:associate_iam_instance_profile, :disassociate_iam_instance_profile)
    expect(log_events).to include("profile_association_planned")
  end

  it "ステップごとに開始・終了のログを出し、失敗したステップは step_failed を出す" do
    stub_profile_association_lifecycle(clients.ec2)

    expect { run_section([recording_step("First", error: AmiPublish::StepFailedError.new("x"))]) }
      .to raise_error(AmiPublish::StepFailedError)

    records = log_output.string.lines.map { |line| JSON.parse(line) }
                        .select { |record| record["event"].start_with?("step_") }
    expect(records.map { |record| [record["event"], record["step"]] }).to eq(
      [%w[step_started AttachReleaseInstanceProfile], %w[step_finished AttachReleaseInstanceProfile],
       %w[step_started First], %w[step_failed First]]
    )
  end
end
