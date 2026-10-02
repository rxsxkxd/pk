# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 4a: ヘルスチェックの後に、リリース用インスタンスからインスタンスプロファイルの紐付けを解除する。
    #
    # 失敗したら AMI は残して失敗にする（ヘルスチェックは通っているため）。このとき interactor が
    # AttachReleaseInstanceProfile の rollback を呼び、もう一度だけ解除を試みる。
    # 紐付けていない実行（ヘルスチェックの省略、dry-run）では何もしない。
    class DetachReleaseInstanceProfile < BaseStep
      include ReleaseInstanceProfileAssociation

      def call
        return unless context.profile_attached

        detach
      rescue Poller::TimeoutError, Aws::Errors::ServiceError => e
        raise StepFailedError, "ヘルスチェックは成功したが、インスタンスプロファイルの紐付けを解除できなかった" \
                               "（#{e.message}）。AMI は残している。同じ実行を再試行するか、手で解除する: #{manual_detach_command}"
      end
    end
  end
end
