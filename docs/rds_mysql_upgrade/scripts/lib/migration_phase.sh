#!/usr/bin/env bash
# 移行元インスタンスの実状態から、移行のどの地点にいるかを判定する共有関数。
# build_green.sh（Step 3）と switchover.sh（Step 5）から source して使う。
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
#   本関数は「結果」を見るため、経路の正しさまでは保証しない。切替を経ずに
#   手動でインプレースアップグレードした場合も post_switchover と判定する。
#   また SWITCHOVER_IN_PROGRESS 中はリネームが未完了のため pre_switchover の
#   ままである。実行中の再入を防ぐには Deployment の Status を併用すること。

# エンジンバージョンから major.minor だけを取り出す。
# 8.0.44 -> 8.0 / 8.4.10 -> 8.4 / 8.0 -> 8.0 / 8 -> 8
migration_phase_major_minor() {
  local version=$1
  local major=${version%%.*}
  local rest=${version#*.}
  # ドットを含まない場合、rest は version と同じになる
  if [[ "$rest" == "$version" ]]; then
    echo "$major"
  else
    echo "${major}.${rest%%.*}"
  fi
}

# 使い方:
#   phase=$(resolve_migration_phase \
#     "$current_version" "$current_group" \
#     "$source_engine_version" "$source_db_parameter_group_name" \
#     "$target_engine_version" "$target_db_parameter_group_name")
#
# 標準出力: pre_switchover | post_switchover | unknown
#
# エンジンバージョンは major.minor に正規化してから比較する。
# 厳密一致にすると、RDS の自動マイナーバージョンアップグレード
# （8.0.44 → 8.0.46、切替後の 8.4.10 → 8.4.11 など）でパイプラインが止まる。
#
# とくに target_engine_version は create-blue-green-deployment の
# --target-engine-version へ渡す都合で完全なパッチ版（8.4.10）を宣言する必要があり、
# 前方一致では切替後のパッチ更新に追随できない。ここが正規化する主な理由である。
#
# 本関数の目的は「旧メジャーバージョンか新メジャーバージョンか」の判別であり、
# major.minor がちょうど必要な粒度である。パッチレベルの厳密な検証は
# create_blue_green_deployment.sh と verify_green.sh が別途行う。
#
# パラメータグループ名は正規化の余地がないため厳密一致とする。
resolve_migration_phase() {
  local current_version=$1 current_group=$2
  local source_version=$3 source_group=$4
  local target_version=$5 target_group=$6

  local current source target
  current=$(migration_phase_major_minor "$current_version")
  source=$(migration_phase_major_minor "$source_version")
  target=$(migration_phase_major_minor "$target_version")

  if [[ "$current" == "$source" && "$current_group" == "$source_group" ]]; then
    echo pre_switchover
  elif [[ "$current" == "$target" && "$current_group" == "$target_group" ]]; then
    echo post_switchover
  else
    echo unknown
  fi
}

# 判定に使った実測値と宣言値を、人が読める形で出力する。
# unknown だった場合に何がずれているのかを示すために使う。
describe_migration_phase_inputs() {
  local current_version=$1 current_group=$2
  local source_version=$3 source_group=$4
  local target_version=$5 target_group=$6

  echo "  実測: engine=${current_version} parameter_group=${current_group}"
  echo "  移行元の宣言: engine=${source_version}* parameter_group=${source_group}"
  echo "  移行先の宣言: engine=${target_version}* parameter_group=${target_group}"
}
