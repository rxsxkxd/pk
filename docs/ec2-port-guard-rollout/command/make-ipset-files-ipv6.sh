#!/bin/bash
# 踏み台サーバーで実行する。IPv6 の一覧から、対象のサーバーで ipset の集合に一覧を入れるファイル（command/port_guard/03-*-ipv6.sh）を作る
set -euo pipefail
mkdir -p command/port_guard
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv6.txt | awk 'NF { print "add port_guard_jp6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp6'; } > command/port_guard/03-jp-ipv6.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv6.txt | awk 'NF { print "add port_guard_allow6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow6'; } > command/port_guard/03-allow-ipv6.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_aws6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/aws-ipv6.txt | awk 'NF { print "add port_guard_aws6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_aws6'; } > command/port_guard/03-aws-ipv6.sh
echo "作った: command/port_guard/03-jp-ipv6.sh・03-allow-ipv6.sh・03-aws-ipv6.sh"
