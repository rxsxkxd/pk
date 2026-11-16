#!/bin/bash
# port-guard を、次の起動から動かないようにする（今入っているルールはそのまま）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') disable"

sudo -n systemctl disable port-guard

# 確認
systemctl is-enabled port-guard || true   # disabled
