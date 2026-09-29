# frozen_string_literal: true

module AmiPublish
  # ステップ間で受け渡す値。
  #   version                 AMI に含まれるアプリのリリースバージョン（例: v1.2.3）
  #   verified                リリースの確認方法（manual: 手動 / automated: リリース検証パイプライン）
  #   pipeline_execution_id   パイプラインの実行 ID。再実行時に作成済みの AMI を見つけるために AMI のタグに付ける
  #   dry_run                 true なら AWS に書き込まず、実行予定の操作をログに出す
  #   image_id                作成した（または戻し先の）AMI の ID
  #   launch_template_version 作成された起動テンプレートのバージョン番号
  #   instance_state_at_start 開始時のリリース用インスタンスの状態（running / stopped）
  #   health_check            false ならヘルスチェックと、そのためだけの処理（SSM の確認、停止中のインスタンスの起動など）を省略する
  RunContext = Struct.new(:version, :verified, :pipeline_execution_id, :dry_run,
                          :image_id, :launch_template_version, :instance_state_at_start, :health_check,
                          keyword_init: true) do
    # 既定ではヘルスチェックを行う（明示的に false を指定したときだけ省略する）
    def health_check?
      health_check != false
    end
  end
end
