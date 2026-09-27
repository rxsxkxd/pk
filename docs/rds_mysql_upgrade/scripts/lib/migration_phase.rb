# frozen_string_literal: true
#
# 移行元インスタンスの実状態から、移行のどの地点にいるかを判定する。
# **判定の実装はここだけである。**build_green.rb / verify_green.rb / switchover.rb が
# require_relative して observe を使う（tools/cleanup は Go 側の tools/internal/phase）。
#
# 判定の根拠:
#   切替時に RDS は blue を <name>-old1 へリネームし、green が <name> を引き継ぐ。
#   このため source_db_instance_identifier が指す実体は、切替の前後で
#   「8.0 + 旧パラメータグループ」から「8.4 + 新パラメータグループ」へ変わる。
#   Deployment というリソースの状態ではなく、達成したい結果そのものを直接観測できる。
#
#   利点は、Deployment が削除された後も判定できることである。cleanup 実行後は
#   describe-blue-green-deployments が何も返さないため、状態機械だけに頼ると
#   「対象が見つからない」としか言えない。
#
# 注意:
#   本判定は「結果」を見るため、経路の正しさまでは保証しない。切替を経ずに
#   手動でインプレースアップグレードした場合も post_switchover と判定する。
#   また SWITCHOVER_IN_PROGRESS 中はリネームが未完了のため pre_switchover の
#   ままである。実行中の再入を防ぐには Deployment の Status を併用すること。
#
# Ruby から:
#   require_relative 'lib/migration_phase'
#   MigrationPhase.observe(config, service_name, aws)   # 設定を読み、移行元を AWS から読んで判定
#   MigrationPhase.resolve(current_version, current_group,
#                          source_version, source_group, target_version, target_group)
#
# コマンドとして（テスト用。AWS を呼ばない）:
#   ruby migration_phase.rb resolve     <現在版> <現在PG> <移行元版> <移行元PG> <移行先版> <移行先PG>
#   ruby migration_phase.rb describe    （同じ 6 引数）
#   ruby migration_phase.rb major-minor <版>
#
# 観測（observe）は AWS の読み取りを伴い、判定そのもの（resolve）は AWS を呼ばない純粋な関数である。
module MigrationPhase
  PRE = 'pre_switchover'
  POST = 'post_switchover'
  UNKNOWN = 'unknown'

  # 観測の結果。declared は判定に使った宣言値（移行元版・移行元 PG・移行先版・移行先 PG）。
  Observation = Struct.new(:phase, :current_version, :current_group, :source_id, :declared, keyword_init: true)

  module_function

  # 設定を読み、移行元の実体を AWS から読んで（読み取りだけ）判定する。
  # config は DeploymentConfig、aws は AwsCli。save を渡すと describe-db-instances の応答を保存する。
  # 失敗は DeploymentConfig::Error / AwsCli::Error として呼び出し側へ伝える。
  def observe(config, service_name, aws, save: nil)
    service = config.service(service_name)
    declared = %w[source_engine_version source_db_parameter_group_name target_engine_version target_db_parameter_group_name]
               .map { |key| service.required(key) }
    source_id = service.required('source_db_instance_identifier')
    # [読み取り] 移行元識別子が指す実体。切替後は green（新 Blue）を指す。
    source = aws.run_json('rds', 'describe-db-instances', '--db-instance-identifier', source_id, save_to: save)
    instance = source.dig('DBInstances', 0) || {}
    version = instance['EngineVersion'].to_s
    group = instance.dig('DBParameterGroups', 0, 'DBParameterGroupName').to_s
    Observation.new(phase: resolve(version, group, *declared), current_version: version, current_group: group,
                    source_id: source_id, declared: declared)
  end

  # エンジンバージョンから major.minor だけを取り出す。
  # 8.0.44 -> 8.0 / 8.4.10 -> 8.4 / 8.0 -> 8.0 / 8 -> 8 / 8.04.0 -> 8.04
  def major_minor(version)
    version.to_s.split('.', -1).first(2).join('.')
  end

  # pre_switchover / post_switchover / unknown を返す。
  #
  # エンジンバージョンは major.minor に正規化してから比較する。
  # 厳密一致にすると、RDS の自動マイナーバージョンアップグレード
  # （8.0.44 → 8.0.46、切替後の 8.4.10 → 8.4.11 など）でパイプラインが止まる。
  #
  # とくに target_engine_version は create-blue-green-deployment の
  # --target-engine-version へ渡す都合で完全なパッチ版（8.4.10）を宣言する必要があり、
  # 前方一致では切替後のパッチ更新に追随できない。ここが正規化する主な理由である。
  # （前方一致だと 8.04 が 8.0 に誤って一致する問題もある。）
  #
  # 目的は「旧メジャーバージョンか新メジャーバージョンか」の判別であり、
  # major.minor がちょうど必要な粒度である。パッチレベルの厳密な検証は
  # create_blue_green_deployment と verify_green が別途行う。
  #
  # パラメータグループ名は正規化の余地がないため厳密一致とする。
  def resolve(current_version, current_group, source_version, source_group, target_version, target_group)
    current = major_minor(current_version)
    if current == major_minor(source_version) && current_group == source_group
      PRE
    elsif current == major_minor(target_version) && current_group == target_group
      POST
    else
      UNKNOWN
    end
  end

  # 判定に使った実測値と宣言値を、人が読める形で返す。
  # unknown だった場合に何がずれているのかを示すために使う。
  def describe_inputs(current_version, current_group, source_version, source_group, target_version, target_group)
    [
      "  実測: engine=#{current_version} parameter_group=#{current_group}",
      "  移行元の宣言: engine=#{source_version}* parameter_group=#{source_group}",
      "  移行先の宣言: engine=#{target_version}* parameter_group=#{target_group}",
    ].join("\n")
  end
end

# コマンドとして呼ばれたときだけ動く（require されたときは何もしない）。
if $PROGRAM_NAME == __FILE__
  command, *arguments = ARGV
  case command
  when 'resolve'
    abort 'resolve には 6 つの引数が要る' unless arguments.size == 6
    puts MigrationPhase.resolve(*arguments)
  when 'describe'
    abort 'describe には 6 つの引数が要る' unless arguments.size == 6
    puts MigrationPhase.describe_inputs(*arguments)
  when 'major-minor'
    abort 'major-minor には 1 つの引数が要る' unless arguments.size == 1
    puts MigrationPhase.major_minor(arguments.first)
  else
    abort "Usage: #{File.basename(__FILE__)} resolve|describe|major-minor ARGS..."
  end
end
