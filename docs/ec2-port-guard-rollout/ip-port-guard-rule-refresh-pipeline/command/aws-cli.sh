#!/bin/bash
# 入口から読み込む。指定は子の bash にも引き継ぎ、すべての AWS CLI 呼び出しに使う。
while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) export AWS_REGION="${2:?--region の値がない}"; shift 2 ;;
    --profile) export AWS_PROFILE="${2:?--profile の値がない}"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 1 ;;
  esac
done

aws() {
  if [ -n "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ]; then
    set -- --region "${AWS_REGION:-$AWS_DEFAULT_REGION}" "$@"
  fi
  if [ -n "${AWS_PROFILE:-}" ]; then
    set -- --profile "$AWS_PROFILE" "$@"
  fi
  command aws "$@"
}
export -f aws
