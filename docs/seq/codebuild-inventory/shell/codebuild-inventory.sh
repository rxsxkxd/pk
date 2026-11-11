#!/usr/bin/env bash
# CodeBuild プロジェクトの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=codebuild-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='last_build:codebuild_project'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  # プロジェクト名を 100 件ずつまとめて定義を引く
  aws_json codebuild list-projects | jq '.projects' | chunks 100 |
    while read -r names; do
      # shellcheck disable=SC2086 # プロジェクト名を別々の引数として渡す
      aws_json codebuild batch-get-projects --names $names | jq -c '.projects[]'
    done >"$work/projects.jsonl"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile projects "$work/projects.jsonl" \
    --slurpfile images "$lib_dir/codebuild-image-os.json" "$jq_lib"'
    # CodeBuild が提供するイメージは名前から OS がわかる。自前のイメージ（ECR など）はわからない
    def os_from_image($image):
      if $image == null then null
      else
        first($images[0][] | select(.pattern as $p | $image | test($p)) | .os)
        // (if $image | startswith("aws/codebuild/") then "Unknown" else "Custom Image" end)
      end;

    $projects[]
    | record("codebuild_project"; {
        project_name: .name,
        project_arn: .arn,
        description: .description,
        environment_type: .environment.type,
        image: .environment.image,
        base_os: os_from_image(.environment.image),
        compute_type: .environment.computeType,
        privileged_mode: .environment.privilegedMode,
        image_pull_credentials_type: .environment.imagePullCredentialsType,
        service_role: .serviceRole,
        source_type: .source.type,
        source_location: .source.location,
        source_version: .sourceVersion,
        webhook: (
          if .webhook == null then null
          else {build_type: .webhook.buildType, filter_group_count: (.webhook.filterGroups // [] | length)}
          end
        ),
        vpc: (
          if (.vpcConfig.vpcId // "") == "" then null
          else {vpc_id: .vpcConfig.vpcId, subnets: (.vpcConfig.subnets // []),
                security_group_ids: (.vpcConfig.securityGroupIds // [])}
          end
        ),
        timeout_in_minutes: .timeoutInMinutes,
        queued_timeout_in_minutes: .queuedTimeoutInMinutes,
        concurrent_build_limit: .concurrentBuildLimit,
        artifacts_type: .artifacts.type,
        cache_type: .cache.type,
        cloudwatch_logs: .logsConfig.cloudWatchLogs.status,
        s3_logs: .logsConfig.s3Logs.status,
        encryption_key: .encryptionKey,
        created_at: (.created | utc_iso),
        last_modified_at: (.lastModified | utc_iso),
        tags: (.tags | tags_object)
      })'
}

# 直近のビルド。ビルドが 1 度も無ければ null。履歴は 1 ページ目だけを取る
detail_last_build() {
  local name id
  name=$(jq -r '.project_name' <<<"$1")
  id=$(aws_paced codebuild list-builds-for-project --project-name "$name" --sort-order DESCENDING --no-paginate |
    jq -r '.ids[0] // ""') || return 1
  if [ -z "$id" ]; then
    echo null
    return 0
  fi
  aws_paced codebuild batch-get-builds --ids "$id" | jq -c "$jq_lib"'.builds[0] | {
    build_id: .id,
    status: .buildStatus,
    current_phase: .currentPhase,
    start_time: (.startTime | utc_iso),
    end_time: (.endTime | utc_iso),
    source_version: .sourceVersion,
    resolved_source_version: .resolvedSourceVersion,
    initiator: .initiator
  }'
}

run_main "$@"
