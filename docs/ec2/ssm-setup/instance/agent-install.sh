#!/bin/bash
# SSM Agent を入れ（入っていなければ）、起動時に有効にして、起動し直す（インスタンスの中の操作）。
# 稼働サーバーの上で bash で動く（root でなければ、root が要るところだけ sudo -n）。AWS の API は呼ばない。
# 稼働サーバーへの届け方（SSH など）は ssm-setup の範囲外。例: ssh centos@<稼働サーバー> 'bash' < instance/agent-install.sh
# 流す前に、rb/backup_check.rb の --ok-out の一覧（バックアップがそろった台）に入っていることを確かめる。
# どの台に流しても同じことをする（入っていれば入れない。動いていても起動し直して、認証情報を取り直させる）。
# OS の再起動は要らない。結果は人が読む形で出す。
set -euo pipefail
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo -n"

echo "== $(hostname) $(date '+%F %T') agent-install"

echo "-- SSM Agent のインストール"
if rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  echo "入っていた（$(rpm -q --qf '%{VERSION}' amazon-ssm-agent)）"
else
  # 標準入力で送ったスクリプトの残りを yum が読んでしまわないように < /dev/null
  $SUDO yum install -y -q amazon-ssm-agent < /dev/null
  echo "今入れた（$(rpm -q --qf '%{VERSION}' amazon-ssm-agent)）"
fi

echo "-- 起動時の有効化と起動し直し"
if [ -d /run/systemd/system ]; then
  $SUDO systemctl enable amazon-ssm-agent
  $SUDO systemctl restart amazon-ssm-agent
  sleep 10
  echo "起動時の有効化: $(systemctl is-enabled amazon-ssm-agent 2>/dev/null || true)"
  echo "動作: $(systemctl is-active amazon-ssm-agent 2>/dev/null || true)"
else
  echo "systemd が動いていないので、飛ばした"
fi

echo "-- SSM Agent の記録の最後"
$SUDO tail -n 20 /var/log/amazon/ssm/amazon-ssm-agent.log 2>/dev/null || echo "（読めない）"

echo "数分置いてから、作業者の PC で rb/ssm_check.rb → connect/ssm-connect-check.sh をもう一度流す"
