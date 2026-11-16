#!/bin/bash
# コンテナでは systemd を動かさないので、SSH のサーバー・cron・Apache をここで起動する
set -euo pipefail

# ログインに使う公開鍵（compose で ./ssh を /run/ssh に読み取り専用で渡す）を、アプリのユーザーの authorized_keys にする
keys_dir=/run/ssh
authorized_keys="/home/${APP_USER}/.ssh/authorized_keys"
if compgen -G "${keys_dir}/*.pub" > /dev/null; then
  cat "${keys_dir}"/*.pub > "${authorized_keys}"
  chown "${APP_USER}:${APP_USER}" "${authorized_keys}"
  chmod 600 "${authorized_keys}"
else
  echo "entrypoint: ${keys_dir} に公開鍵（*.pub）がないので、SSH ではログインできない" >&2
fi

/usr/sbin/sshd
crond
exec /usr/sbin/httpd -DFOREGROUND
