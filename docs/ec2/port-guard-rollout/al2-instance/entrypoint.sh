#!/bin/bash
# コンテナでは systemd を動かさないので、cron と Apache をここで起動する
set -euo pipefail

crond
exec /usr/sbin/httpd -DFOREGROUND
