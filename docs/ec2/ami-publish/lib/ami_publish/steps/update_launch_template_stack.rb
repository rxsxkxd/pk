# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 5: 起動テンプレートのスタックを、パラメータ AmiId / AppVersion だけ変えて更新する。
    #
    # テンプレート本体は変えず（UsePreviousTemplate）、ほかのパラメータは現在の値を引き継ぐ。
    # 変更セットを作って差分を検証し、起動テンプレート（AWS::EC2::LaunchTemplate）の変更以外が含まれていたら
    # 実行せずに中止する（テンプレートが別経路で変更された場合の安全装置）。
    #
    # 失敗しても AMI は削除しない。AMI 自体は正常なので、同じパイプライン実行を再実行したときに再利用する。
    #
    # CloudFormation のサービスロールは渡さない（CodeBuild の権限で変更セットを実行する）。サービスロールを渡すと
    # スタックがそのロールを覚え、担当者の再デプロイや削除までそのロールで実行されるようになるため。
    class UpdateLaunchTemplateStack < BaseStep
      MANAGED_PARAMETERS = %w[AmiId AppVersion].freeze
      STABLE_STATUSES = %w[CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE
                           IMPORT_COMPLETE IMPORT_ROLLBACK_COMPLETE].freeze
      NO_CHANGE_REASONS = ["didn't contain changes", "No updates are to be performed"].freeze

      def call
        stack = describe_stack(stack_name)
        verify_stack(stack)

        if context.image_id.nil?
          logger.info("launch_template_stack_update_planned", stack_name: stack_name,
                                                              parameters: { AmiId: "（ステップ 1 で作成する AMI）",
                                                                            AppVersion: context.version })
          return
        end

        current = parameter_values(stack)
        return record_already_applied(stack) if current["AmiId"] == context.image_id &&
                                                current["AppVersion"] == context.version

        update_with_change_set(context, current.keys)
      end

      private

      def record_already_applied(stack)
        context.launch_template_version = launch_template_version(stack)
        logger.info("launch_template_stack_already_applied", stack_name: stack_name, image_id: context.image_id,
                                                             launch_template_version: context.launch_template_version)
      end

      def stack_name
        @stack_name ||= launch_template_stack_name
      end

      def update_with_change_set(context, parameter_keys)
        change_set_name = "#{context.change_set_prefix || 'ami-publish'}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
        create_change_set(change_set_name, context, parameter_keys)
        changes = wait_for_change_set(change_set_name)
        if changes.nil?
          context.launch_template_version = launch_template_version(describe_stack(stack_name))
          return
        end

        verify_changes(change_set_name, changes)
        if context.dry_run
          delete_change_set(change_set_name, reason: "dry-run のため実行しない")
          return
        end

        execute_change_set(change_set_name)
        context.launch_template_version = launch_template_version(describe_stack(stack_name))
        logger.info("launch_template_stack_updated", stack_name: stack_name, image_id: context.image_id,
                                                     launch_template_version: context.launch_template_version)
      end

      def create_change_set(change_set_name, context, parameter_keys)
        # [変更] 変更セットを作成する（まだ反映しない）
        clients.cloudformation.create_change_set(
          stack_name: stack_name,
          change_set_name: change_set_name,
          change_set_type: "UPDATE",
          use_previous_template: true,
          parameters: build_parameters(parameter_keys, context),
          capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM],
          description: "ami-publish: #{context.version} #{context.image_id}"
        )
        logger.info("change_set_created", stack_name: stack_name, change_set_name: change_set_name)
      end

      # 変更がなければ nil を返す（変更セットは削除する）。
      def wait_for_change_set(change_set_name)
        progress = progress_logger("変更セットの作成")
        clients.cloudformation.wait_until(:change_set_create_complete, stack_name: stack_name,
                                                                       change_set_name: change_set_name) do |waiter|
          configure_waiter(waiter, configuration.stack_update_timeout_seconds, progress: progress) do |response|
            { change_set_name: change_set_name, status: response.data&.status }
          end
        end
        all_changes(change_set_name)
      rescue Aws::Waiters::Errors::WaiterFailed => e
        reason = describe_change_set(change_set_name).status_reason.to_s
        if NO_CHANGE_REASONS.any? { |text| reason.include?(text) }
          delete_change_set(change_set_name, reason: "変更がない")
          return nil
        end

        delete_change_set(change_set_name, reason: "変更セットの作成に失敗した")
        raise StepFailedError, "変更セットの作成に失敗した: #{reason.empty? ? e.message : reason}"
      end

      def verify_changes(change_set_name, changes)
        summaries = changes.map { |change| summarize(change) }
        logger.info("change_set_changes", change_set_name: change_set_name, changes: summaries)

        unexpected = changes.reject { |change| allowed_change?(change) }
        return if unexpected.empty?

        delete_change_set(change_set_name, reason: "想定外の差分がある")
        raise StepFailedError,
              "起動テンプレート以外の変更が含まれているため中止した: #{unexpected.map { |c| summarize(c) }.join(', ')}"
      end

      # 許可する変更は、起動テンプレートの置換を伴わない変更（Modify）だけ。
      def allowed_change?(change)
        resource = change.resource_change
        change.type == "Resource" && resource &&
          resource.resource_type == "AWS::EC2::LaunchTemplate" &&
          resource.action == "Modify" && resource.replacement != "True"
      end

      def summarize(change)
        resource = change.resource_change
        return change.type.to_s unless resource

        "#{resource.action} #{resource.resource_type} #{resource.logical_resource_id} " \
          "(replacement: #{resource.replacement || '-'})"
      end

      def execute_change_set(change_set_name)
        # [変更] 変更セットを実行し、起動テンプレートの新しいバージョンを作る
        clients.cloudformation.execute_change_set(stack_name: stack_name, change_set_name: change_set_name)
        progress = progress_logger("起動テンプレートのスタックの更新")
        clients.cloudformation.wait_until(:stack_update_complete, stack_name: stack_name) do |waiter|
          configure_waiter(waiter, configuration.stack_update_timeout_seconds, progress: progress) do |response|
            stack = response.data&.stacks&.first
            { stack_name: stack_name, stack_status: stack&.stack_status }
          end
        end
      rescue Aws::Waiters::Errors::WaiterFailed => e
        status = describe_stack(stack_name).stack_status
        raise StepFailedError, "スタックの更新が完了しなかった（状態: #{status}）: #{e.message}"
      end

      def delete_change_set(change_set_name, reason:)
        clients.cloudformation.delete_change_set(stack_name: stack_name, change_set_name: change_set_name)
        logger.info("change_set_deleted", change_set_name: change_set_name, reason: reason)
      end

      def all_changes(change_set_name)
        changes = []
        next_token = nil
        loop do
          response = describe_change_set(change_set_name, next_token: next_token)
          changes.concat(response.changes)
          next_token = response.next_token
          break if next_token.nil?
        end
        changes
      end

      def describe_change_set(change_set_name, next_token: nil)
        clients.cloudformation.describe_change_set(stack_name: stack_name, change_set_name: change_set_name,
                                                   next_token: next_token)
      end

      def describe_stack(name)
        clients.cloudformation.describe_stacks(stack_name: name).stacks.first
      end

      def verify_stack(stack)
        unless STABLE_STATUSES.include?(stack.stack_status)
          raise StepFailedError, "スタック #{stack_name} が更新できる状態ではない（状態: #{stack.stack_status}）"
        end

        missing = MANAGED_PARAMETERS - parameter_values(stack).keys
        return if missing.empty?

        raise StepFailedError, "スタック #{stack_name} にパラメータ #{missing.join(', ')} がない"
      end

      def parameter_values(stack)
        stack.parameters.to_h { |parameter| [parameter.parameter_key, parameter.parameter_value] }
      end

      # AmiId / AppVersion 以外のパラメータは現在の値を引き継ぐ。指定しないと既定値に戻ってしまうため。
      def build_parameters(parameter_keys, context)
        parameter_keys.map do |key|
          case key
          when "AmiId" then { parameter_key: key, parameter_value: context.image_id }
          when "AppVersion" then { parameter_key: key, parameter_value: context.version }
          else { parameter_key: key, use_previous_value: true }
          end
        end
      end

      def launch_template_version(stack)
        output_value(stack, "LaunchTemplateVersion")
      end

      def output_value(stack, key)
        output = stack.outputs.find { |candidate| candidate.output_key == key }
        raise StepFailedError, "スタック #{stack.stack_name} に出力 #{key} がない" unless output

        output.output_value
      end
    end
  end
end
