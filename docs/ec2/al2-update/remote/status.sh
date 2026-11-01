# インスタンスの今の状態を返す（読み取りだけ）。更新の前（rb/check.rb）にも後（rb/update.rb）にも、つなげて送る。
# 前置きで AU_HEALTH_URL が渡される（空なら、アプリの応答は見ない）。root で実行する。
# 前につなげたスクリプトの set -e を引き継がないように、ここで外す（needs-restarting などは 0 以外で終わることがある）。
set +e +o pipefail
set -u
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
printf 'PGSTEP %s\n' "今の状態の確認"

kv kernel_running "$(uname -r)"
kv kernel_newest "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel 2>/dev/null | sort -V | tail -1)"
if command -v needs-restarting >/dev/null 2>&1; then
  needs-restarting -r >/dev/null 2>&1
  case $? in 0) v=no ;; 1) v=yes ;; *) v=unknown ;; esac
  kv needs_reboot "$v"
  kv restart_services "$(needs-restarting -s 2>/dev/null | paste -sd, -)"
else
  kv needs_reboot "unknown（yum-utils がない）"
  kv restart_services "unknown（yum-utils がない）"
fi

for package in httpd mod_ssl openssl-libs openssl11-libs; do
  v=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$package" 2>/dev/null) || v=none
  kv "version_${package//-/_}" "$v"
done
v=$(ldd /etc/httpd/modules/mod_ssl.so 2>/dev/null | awk '/libssl/ { print $1 }' | paste -sd, -)
kv mod_ssl_libssl "${v:-none}"
v=$(systemctl is-active httpd 2>/dev/null)
kv httpd_active "${v:-unknown}"
v=$(systemctl is-enabled yum-cron 2>/dev/null)
kv yum_cron_enabled "${v:-none}"

if [ -n "${AU_HEALTH_URL:-}" ]; then
  # 証明書は確かめない（自己署名や、名前の合わない証明書でも応答を見る）。転送（3xx）は追わない
  v=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "$AU_HEALTH_URL" 2>/dev/null)
  kv health_code "${v:-000}"
else
  kv health_code skipped
fi
