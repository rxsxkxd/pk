# frozen_string_literal: true

module AmiPublish
  module Steps
    # 開始前の確認: リリース用インスタンスのロール（インスタンスプロファイル）に、必要な許可があるかを確かめる。
    #
    # IAM のポリシーシミュレーター（SimulatePrincipalPolicy）で、ロールのポリシー上、必要な操作を
    # 実際の対象に対して実行できるかを判定する（AWS の操作は実行しない）。インスタンスが停止中でも確認できる。
    # 許可の一覧と設定方法は docs/ec2/ami-publish-release-instance-iam.md。
    #
    #   A. SSM の管理対象（AmazonSSMManagedInstanceCore 相当）
    #   B. ヘルスチェックの出力を CloudWatch Logs に送る
    #   C. Basic 認証のパラメーターの読み取り（health_check.basic_auth_parameter_name を設定した場合）
    #
    # A・C が不足していれば、不足している許可を一覧にして失敗する（AMI は作らない）。
    # B が不足していても、ヘルスチェック自体は動く（出力がロググループに残らないだけ）ため、警告のログを出して先に進む。
    # ヘルスチェックを省略する実行では、これらの許可を使わないため、判定しない。
    # Basic 認証のパラメーターは、既定の aws/ssm キーで暗号化した SecureString であることも確かめる
    # （既定のキーなら KMS の許可は不要。カスタマー管理キーには対応しない）。
    class CheckReleaseInstancePermissions < BaseStep
      IAM_DOCUMENT = "docs/ec2/ami-publish-release-instance-iam.md"
      DEFAULT_SSM_KEY = "alias/aws/ssm"

      # required: false の区分は、不足していても警告にとどめる
      Check = Struct.new(:label, :actions, :resource, :required, keyword_init: true)

      def call(context)
        return if skipped_without_health_check?(context, "release_instance_permissions_check_skipped")

        role_arn = release_instance_role_arn
        checks = permission_checks(role_arn)
        required, optional = checks.partition { |check| check.required != false }
        missing = required.flat_map { |check| missing_actions(role_arn, check) }
        warnings = optional.flat_map { |check| missing_actions(role_arn, check) }
        logger.info("release_instance_permissions_checked", role_arn: role_arn, checks: checks.map(&:label),
                                                            missing: missing, warnings: warnings)
        report_warnings(warnings)
        report_missing(role_arn, missing)
      end

      private

      def report_warnings(warnings)
        return if warnings.empty?

        logger.error("release_instance_permissions_warning",
                     message: "必須ではない許可が足りない（処理は続ける）。設定方法は #{IAM_DOCUMENT} を参照",
                     missing: warnings)
      end

      def report_missing(role_arn, missing)
        return if missing.empty?

        raise StepFailedError, "リリース用インスタンスのロール #{role_arn} に必要な許可が足りない。AMI は作成していない。" \
                               "不足: #{missing.join(' / ')}。設定方法は #{IAM_DOCUMENT} を参照"
      end

      def release_instance_role_arn
        instance = clients.ec2.describe_instances(instance_ids: [configuration.release_instance_id])
                          .reservations.flat_map(&:instances).first
        profile_arn = instance&.iam_instance_profile&.arn
        unless profile_arn
          raise StepFailedError, "リリース用インスタンス #{configuration.release_instance_id} に" \
                                 "インスタンスプロファイル（IAM ロール）が付いていない。設定方法は #{IAM_DOCUMENT} を参照"
        end

        profile_name = profile_arn.split("/").last
        role = clients.iam.get_instance_profile(instance_profile_name: profile_name).instance_profile.roles.first
        raise StepFailedError, "インスタンスプロファイル #{profile_name} にロールが入っていない" unless role

        role.arn
      end

      def permission_checks(role_arn)
        partition, account_id = role_arn.split(":").values_at(1, 4)
        region = configuration.aws_region
        checks = [ssm_managed_check, log_output_check(partition, region, account_id)]
        parameter_name = configuration.basic_auth_parameter_name
        return checks unless parameter_name

        verify_basic_auth_parameter(parameter_name)
        checks << Check.new(label: "C. Basic 認証のパラメーターの読み取り", actions: ["ssm:GetParameter"],
                            resource: "arn:#{partition}:ssm:#{region}:#{account_id}:parameter#{parameter_name}")
      end

      def ssm_managed_check
        Check.new(label: "A. SSM の管理対象（AmazonSSMManagedInstanceCore）",
                  actions: %w[ssm:UpdateInstanceInformation
                              ssmmessages:CreateControlChannel ssmmessages:CreateDataChannel
                              ssmmessages:OpenControlChannel ssmmessages:OpenDataChannel
                              ec2messages:GetMessages ec2messages:AcknowledgeMessage ec2messages:SendReply],
                  resource: "*")
      end

      def log_output_check(partition, region, account_id)
        Check.new(label: "B. ヘルスチェックの出力を CloudWatch Logs に送る", required: false,
                  actions: %w[logs:CreateLogStream logs:PutLogEvents logs:DescribeLogStreams],
                  resource: "arn:#{partition}:logs:#{region}:#{account_id}:log-group:#{log_group_name}:*")
      end

      # Basic 認証のパラメーターの前提を確かめる: 存在し、SecureString で、既定の aws/ssm キーで暗号化されていること。
      # 既定のキーなら、ロールに KMS の許可は不要（カスタマー管理キーには対応しない）。
      def verify_basic_auth_parameter(parameter_name)
        filters = [{ key: "Name", option: "Equals", values: [parameter_name] }]
        parameter = clients.ssm.describe_parameters(parameter_filters: filters).parameters.first
        raise StepFailedError, "Basic 認証のパラメーター #{parameter_name} がない" unless parameter
        unless parameter.type == "SecureString"
          raise StepFailedError, "Basic 認証のパラメーター #{parameter_name} は SecureString にする（現在: #{parameter.type}）"
        end
        return if [nil, DEFAULT_SSM_KEY].include?(parameter.key_id)

        raise StepFailedError, "Basic 認証のパラメーター #{parameter_name} は、既定の aws/ssm キーで暗号化する" \
                               "（現在: #{parameter.key_id}。カスタマー管理の KMS キーには対応しない）。" \
                               "--key-id を指定せずに作り直す"
      end

      # 許可されていない操作を「区分: 操作（判定）」の形で返す。
      def missing_actions(role_arn, check)
        results = simulate(role_arn, check)
        results.reject { |result| result.eval_decision == "allowed" }
               .map { |result| "#{check.label}: #{result.eval_action_name}（#{result.eval_decision}）" }
      end

      def simulate(role_arn, check)
        results = []
        marker = nil
        loop do
          response = clients.iam.simulate_principal_policy(
            policy_source_arn: role_arn, action_names: check.actions, resource_arns: [check.resource],
            marker: marker
          )
          results.concat(response.evaluation_results)
          break unless response.is_truncated

          marker = response.marker
        end
        results
      end
    end
  end
end
