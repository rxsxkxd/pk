# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::UpdateLaunchTemplateStack do
  subject(:step) { step_with(described_class, **step_dependencies(clients)) }

  let(:clients) { stub_clients }
  let(:cloudformation) { clients.cloudformation }
  let(:launch_template_stack_status) { "UPDATE_COMPLETE" }
  let(:current_parameters) { { "AmiId" => "ami-old", "AppVersion" => "v1.2.2", "InstanceType" => "t3.small" } }
  let(:launch_template_change) do
    { type: "Resource", resource_change: { action: "Modify", logical_resource_id: "LaunchTemplate",
                                           resource_type: "AWS::EC2::LaunchTemplate", replacement: "False" } }
  end
  let(:changes) { [launch_template_change] }
  let(:state) { { executed: false } }
  let(:pipeline_stack) { stack("myapp-staging-ami-publish-pipeline", status: "UPDATE_COMPLETE") }

  def stack(name, status:, parameters: {}, outputs: {})
    { stack_name: name, creation_time: Time.now, stack_status: status,
      parameters: parameters.map { |key, value| { parameter_key: key, parameter_value: value } },
      outputs: outputs.map { |key, value| { output_key: key, output_value: value } } }
  end

  before do
    cloudformation.stub_responses(:describe_stacks, lambda { |request|
      if request.params[:stack_name] == "myapp-staging-ami-publish-pipeline"
        { stacks: [pipeline_stack] }
      else
        status = launch_template_stack_status
        if state[:executed]
          # 実行直後の 1 回は更新中、その後に完了（進捗ログの確認のため）
          state[:polls] = state.fetch(:polls, 0) + 1
          status = state[:polls] == 1 ? "UPDATE_IN_PROGRESS" : "UPDATE_COMPLETE"
        end
        version = state[:executed] ? "4" : "3"
        { stacks: [stack("myapp-staging-launch-template", status: status, parameters: current_parameters,
                                                          outputs: { "LaunchTemplateVersion" => version })] }
      end
    })
    cloudformation.stub_responses(:create_change_set, id: "change-set-arn", stack_id: "stack-arn")
    cloudformation.stub_responses(:describe_change_set, ->(_) { { status: "CREATE_COMPLETE", changes: changes } })
    cloudformation.stub_responses(:execute_change_set, lambda { |_|
      state[:executed] = true
      {}
    })
  end

  it "パラメータ AmiId / AppVersion だけを変える変更セットを作り、差分を検証してから実行する" do
    run_context = context(image_id: "ami-new")

    step.call(run_context)

    params = requests(cloudformation, :create_change_set).first[:params]
    expect(params).to include(stack_name: "myapp-staging-launch-template", change_set_type: "UPDATE",
                              use_previous_template: true)
    # CloudFormation のサービスロールは渡さない（スタックにロールを覚えさせない）
    expect(params).not_to have_key(:role_arn)
    expect(params[:parameters]).to contain_exactly(
      { parameter_key: "AmiId", parameter_value: "ami-new" },
      { parameter_key: "AppVersion", parameter_value: "v1.2.3" },
      { parameter_key: "InstanceType", use_previous_value: true }
    )
    expect(requests(cloudformation, :execute_change_set).size).to eq(1)
    expect(run_context.launch_template_version).to eq("4")
    expect(waiting_logs.first).to include("description" => "起動テンプレートのスタックの更新",
                                          "stack_status" => "UPDATE_IN_PROGRESS")
  end

  context "起動テンプレート以外の変更が含まれている場合" do
    let(:changes) do
      [launch_template_change,
       { type: "Resource", resource_change: { action: "Modify", logical_resource_id: "InstanceRole",
                                              resource_type: "AWS::IAM::Role", replacement: "False" } }]
    end

    it "変更セットを削除して中止し、AMI は削除しない" do
      expect { step.call(context(image_id: "ami-new")) }
        .to raise_error(AmiPublish::StepFailedError, /AWS::IAM::Role InstanceRole/)
      expect(requests(cloudformation, :delete_change_set).size).to eq(1)
      expect(requests(cloudformation, :execute_change_set)).to be_empty
      expect(requests(clients.ec2, :deregister_image)).to be_empty
    end
  end

  context "起動テンプレートが置換される変更の場合" do
    let(:changes) do
      [{ type: "Resource", resource_change: { action: "Modify", logical_resource_id: "LaunchTemplate",
                                              resource_type: "AWS::EC2::LaunchTemplate", replacement: "True" } }]
    end

    it "中止する" do
      expect { step.call(context(image_id: "ami-new")) }.to raise_error(AmiPublish::StepFailedError)
      expect(requests(cloudformation, :execute_change_set)).to be_empty
    end
  end

  context "初回のデプロイで AmiId / AppVersion が空の場合" do
    let(:current_parameters) { { "AmiId" => "", "AppVersion" => "" } }

    it "最初の公開で AMI とバージョンを設定する" do
      step.call(context(image_id: "ami-new"))

      expect(requests(cloudformation, :create_change_set).first[:params][:parameters]).to contain_exactly(
        { parameter_key: "AmiId", parameter_value: "ami-new" },
        { parameter_key: "AppVersion", parameter_value: "v1.2.3" }
      )
      expect(requests(cloudformation, :execute_change_set).size).to eq(1)
    end
  end

  context "同じ AMI とバージョンが適用済みの場合" do
    let(:current_parameters) { { "AmiId" => "ami-new", "AppVersion" => "v1.2.3" } }

    it "変更セットを作らずに成功する（再実行時）" do
      run_context = context(image_id: "ami-new")

      step.call(run_context)

      expect(requests(cloudformation, :create_change_set)).to be_empty
      expect(run_context.launch_template_version).to eq("3")
    end
  end

  context "変更セットに変更がない場合" do
    before do
      cloudformation.stub_responses(:describe_change_set,
                                    status: "FAILED",
                                    status_reason: "The submitted information didn't contain changes.",
                                    changes: [])
    end

    it "変更セットを削除し、実行せずに成功する" do
      run_context = context(image_id: "ami-new")

      step.call(run_context)

      expect(requests(cloudformation, :delete_change_set).size).to eq(1)
      expect(requests(cloudformation, :execute_change_set)).to be_empty
      expect(run_context.launch_template_version).to eq("3")
    end
  end

  context "スタックが更新できる状態ではない場合" do
    let(:launch_template_stack_status) { "UPDATE_IN_PROGRESS" }

    it "変更セットを作らずに失敗する" do
      expect { step.call(context(image_id: "ami-new")) }
        .to raise_error(AmiPublish::StepFailedError, /UPDATE_IN_PROGRESS/)
      expect(requests(cloudformation, :create_change_set)).to be_empty
    end
  end

  context "スタックの更新が失敗してロールバックされた場合" do
    before do
      cloudformation.stub_responses(:execute_change_set, lambda { |_|
        state[:rolled_back] = true
        {}
      })
      cloudformation.stub_responses(:describe_stacks, lambda { |request|
        if request.params[:stack_name] == "myapp-staging-ami-publish-pipeline"
          { stacks: [pipeline_stack] }
        else
          status = state[:rolled_back] ? "UPDATE_ROLLBACK_COMPLETE" : "UPDATE_COMPLETE"
          { stacks: [stack("myapp-staging-launch-template", status: status, parameters: current_parameters,
                                                            outputs: { "LaunchTemplateVersion" => "3" })] }
        end
      })
    end

    it "失敗にし、AMI は削除しない（同じ実行の再実行で再利用する）" do
      expect { step.call(context(image_id: "ami-new")) }
        .to raise_error(AmiPublish::StepFailedError, /UPDATE_ROLLBACK_COMPLETE/)
      expect(requests(clients.ec2, :deregister_image)).to be_empty
    end
  end

  it "dry-run では変更セットで差分を確認し、実行せずに削除する" do
    step.call(context(image_id: "ami-new", dry_run: true))

    expect(requests(cloudformation, :create_change_set).size).to eq(1)
    expect(requests(cloudformation, :delete_change_set).size).to eq(1)
    expect(requests(cloudformation, :execute_change_set)).to be_empty
    expect(log_events).to include("change_set_changes")
  end

  it "AMI がまだない（run の dry-run）場合は、変更予定のパラメータだけをログに出す" do
    step.call(context(image_id: nil, dry_run: true))

    expect(requests(cloudformation, :create_change_set)).to be_empty
    expect(log_events).to include("launch_template_stack_update_planned")
  end
end
