# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AmiPublish::Steps::CheckReleaseInstancePermissions do
  let(:clients) { stub_clients }
  let(:role_arn) { "arn:aws:iam::123456789012:role/release-instance" }
  let(:parameter_name) { "/myapp/staging/health-check/basic-auth" }

  def step(settings = {})
    described_class.new(**step_dependencies(clients,
                                            configuration: configuration("health_check" => settings)))
  end

  def stub_role(profile: "arn:aws:iam::123456789012:instance-profile/release-instance")
    instance = { instance_id: "i-0123456789abcdef0", state: { name: "running" } }
    instance[:iam_instance_profile] = { arn: profile } if profile
    clients.ec2.stub_responses(:describe_instances, reservations: [{ instances: [instance] }])
    clients.iam.stub_responses(:get_instance_profile, instance_profile: {
                                 path: "/", instance_profile_name: "release-instance", instance_profile_id: "id",
                                 arn: profile.to_s, create_date: Time.now,
                                 roles: [{ path: "/", role_name: "release-instance", role_id: "id", arn: role_arn,
                                           create_date: Time.now }]
                               })
  end

  # 指定した操作だけを拒否（implicitDeny）するシミュレーターのスタブ
  def stub_simulation(denied: [])
    clients.iam.stub_responses(:simulate_principal_policy, lambda { |request|
      { is_truncated: false, evaluation_results: request.params[:action_names].map do |action|
        { eval_action_name: action, eval_decision: denied.include?(action) ? "implicitDeny" : "allowed" }
      end }
    })
  end

  def simulated(key)
    requests(clients.iam, :simulate_principal_policy).map { |request| request[:params][key] }
  end

  it "必要な許可がすべてあれば成功する（A・B を、ロググループの ARN に対して判定する）" do
    stub_role
    stub_simulation

    expect { step.call(context) }.not_to raise_error

    expect(simulated(:policy_source_arn).uniq).to eq([role_arn])
    expect(simulated(:action_names).flatten).to include("ssm:UpdateInstanceInformation", "logs:PutLogEvents")
    expect(simulated(:resource_arns).flatten)
      .to include("arn:aws:logs:ap-northeast-1:123456789012:log-group:/myapp/staging/ami-publish:*")
  end

  it "必須の許可（A）が足りなければ、不足している許可を一覧にして失敗する" do
    stub_role
    stub_simulation(denied: %w[ssm:UpdateInstanceInformation])

    expect { step.call(context) }.to raise_error(AmiPublish::StepFailedError) { |error|
      expect(error.message)
        .to include("A. SSM の管理対象（AmazonSSMManagedInstanceCore）: ssm:UpdateInstanceInformation（implicitDeny）")
      expect(error.message).to include("ami-publish-release-instance-iam.md")
    }
  end

  it "B（CloudWatch Logs への出力）だけが足りない場合は、警告のログを出して先に進む" do
    stub_role
    stub_simulation(denied: %w[logs:PutLogEvents])

    expect { step.call(context) }.not_to raise_error
    expect(log_events).to include("release_instance_permissions_warning")
    warning = log_output.string.lines.map { |line| JSON.parse(line) }
                        .find { |record| record["event"] == "release_instance_permissions_warning" }
    expect(warning["missing"]).to eq(["B. ヘルスチェックの出力を CloudWatch Logs に送る: logs:PutLogEvents（implicitDeny）"])
  end

  it "A と B が足りない場合は、A の不足で失敗し、B は警告に出す" do
    stub_role
    stub_simulation(denied: %w[ssm:UpdateInstanceInformation logs:PutLogEvents])

    expect { step.call(context) }.to raise_error(AmiPublish::StepFailedError) { |error|
      expect(error.message).not_to include("logs:PutLogEvents")
    }
    expect(log_events).to include("release_instance_permissions_warning")
  end

  it "インスタンスプロファイルが付いていなければ失敗する" do
    stub_role(profile: nil)

    expect { step.call(context) }.to raise_error(AmiPublish::StepFailedError, /インスタンスプロファイル/)
  end

  context "Basic 認証のパラメーターを設定している場合" do
    let(:settings) { { "url" => "http://localhost/up", "basic_auth_parameter_name" => parameter_name } }

    def stub_parameter(type: "SecureString", key_id: "alias/aws/ssm")
      parameter = { name: parameter_name, type: type, key_id: key_id }
      clients.ssm.stub_responses(:describe_parameters, parameters: [parameter])
    end

    it "既定の aws/ssm キーの SecureString なら、C（パラメーターの読み取り）を判定する（KMS は判定しない）" do
      stub_role
      stub_simulation
      stub_parameter

      step(settings).call(context)

      expect(simulated(:resource_arns).flatten)
        .to include("arn:aws:ssm:ap-northeast-1:123456789012:parameter/myapp/staging/health-check/basic-auth")
      expect(simulated(:action_names).flatten).not_to include("kms:Decrypt")
    end

    it "カスタマー管理の KMS キーで暗号化されていたら、対応しないため失敗する" do
      stub_role
      stub_parameter(key_id: "arn:aws:kms:ap-northeast-1:123456789012:key/abcd")

      expect { step(settings).call(context) }.to raise_error(AmiPublish::StepFailedError, %r{既定の aws/ssm キー})
    end

    it "SecureString でなければ失敗する" do
      stub_role
      stub_parameter(type: "String", key_id: nil)

      expect { step(settings).call(context) }.to raise_error(AmiPublish::StepFailedError, /SecureString/)
    end

    it "パラメーターがなければ失敗する" do
      stub_role
      clients.ssm.stub_responses(:describe_parameters, parameters: [])

      expect { step(settings).call(context) }.to raise_error(AmiPublish::StepFailedError, /パラメーター .* がない/)
    end
  end
end
