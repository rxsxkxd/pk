# frozen_string_literal: true

module AmiPublish
  module Steps
    # 各ステップの共通部分。ステップは call(context) で処理し、結果を context に書き込む。
    class BaseStep
      def initialize(configuration:, clients:, logger:, poller: nil, image_cleanup: nil)
        @configuration = configuration
        @clients = clients
        @logger = logger
        @poller = poller || Poller.new(interval_seconds: configuration.poll_interval_seconds)
        @image_cleanup = image_cleanup || ImageCleanup.new(ec2: clients.ec2, logger: logger)
      end

      private

      attr_reader :configuration, :clients, :logger, :poller, :image_cleanup

      # AWS SDK の待機処理（waiter）の設定。待機時間の上限を確認間隔で割った回数だけ確認する。
      def configure_waiter(waiter, timeout_seconds)
        interval = configuration.poll_interval_seconds
        waiter.delay = interval
        waiter.max_attempts = interval.zero? ? 3 : (timeout_seconds.to_f / interval).ceil
      end

      def application_tag_filters
        [{ name: "tag:App", values: [configuration.application_name] }]
      end
    end
  end
end
