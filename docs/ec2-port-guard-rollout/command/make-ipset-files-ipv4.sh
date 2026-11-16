#!/bin/bash
# 踏み台サーバーで実行する。IPv4 の一覧から、対象のサーバーで ipset の集合に一覧を入れるファイル（command/port_guard/03-*-ipv4.sh）を作る
set -euo pipefail
mkdir -p command/port_guard
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv4.txt | awk 'NF { print "add port_guard_jp " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp'; } > command/port_guard/03-jp-ipv4.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv4.txt | awk 'NF { print "add port_guard_allow " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow'; } > command/port_guard/03-allow-ipv4.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_aws'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/aws-ipv4.txt | awk 'NF { print "add port_guard_aws " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_aws'; } > command/port_guard/03-aws-ipv4.sh
echo "作った: command/port_guard/03-jp-ipv4.sh・03-allow-ipv4.sh・03-aws-ipv4.sh"
