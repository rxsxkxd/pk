#!/bin/bash
# 踏み台サーバーで実行する。一覧を確かめてから、各サーバーで ipset の集合を入れ替えるファイルを作る
# 使い方: bash command/make-refresh.sh（増減の基準で止まり、内容を確かめたうえで進めるときは FORCE=1 bash command/make-refresh.sh）
set -euo pipefail
LISTS=port_guard_whitelists
LAST=$LISTS/last-refresh
MAX_CHANGE_PERCENT=5
mkdir -p command/port_guard "$LAST"

# 1. 一覧を確かめる（一覧の名前:下限の件数。許可の一覧は 0 件でもよく、増減の基準も当てない）
too_few=0
too_changed=0
for item in jp-ipv4:1000 jp-ipv6:200 aws-ipv4:100 aws-ipv6:50 allow-ipv4:0 allow-ipv6:0; do
  name=${item%:*}
  min=${item#*:}
  sed 's/#.*//' "$LISTS/$name.txt" | awk 'NF { print $1 }' | LC_ALL=C sort -u > "$LAST/$name.new"
  count=$(wc -l < "$LAST/$name.new" | tr -d ' ')
  if [ "$count" -lt "$min" ]; then
    echo "${name}: ${count} 件で、下限の ${min} 件より少ない"
    too_few=1
  fi
  if [ -f "$LAST/$name.txt" ]; then
    last=$(wc -l < "$LAST/$name.txt" | tr -d ' ')
    added=$(LC_ALL=C comm -13 "$LAST/$name.txt" "$LAST/$name.new" | wc -l | tr -d ' ')
    removed=$(LC_ALL=C comm -23 "$LAST/$name.txt" "$LAST/$name.new" | wc -l | tr -d ' ')
    echo "${name}: ${count} 件（前回 ${last} 件、増 ${added} 件、減 ${removed} 件）"
    if [ "$min" -gt 0 ] && [ "$last" -gt 0 ] && [ $(( (added + removed) * 100 )) -gt $(( MAX_CHANGE_PERCENT * last )) ]; then
      echo "${name}: 前回からの増減が ${MAX_CHANGE_PERCENT}% を超えている"
      too_changed=1
    fi
  else
    echo "${name}: ${count} 件（前回の記録なし）"
  fi
done
if [ "$too_few" = 1 ]; then
  echo "件数が足りない一覧があるので止める（一覧を作り直して確かめる）"
  exit 1
fi
if [ "$too_changed" = 1 ] && [ "${FORCE:-0}" != 1 ]; then
  echo "増減が大きい一覧があるので止める（内容を確かめて、問題なければ FORCE=1 を付けて流す）"
  exit 1
fi

# 2. 各サーバーに送るファイルを作る（IPv4 と IPv6 で 1 つずつ）
for family in ipv4 ipv6; do
  if [ "$family" = ipv4 ]; then
    s=''; inet=inet; jp_min=1000; aws_min=100
  else
    s=6; inet=inet6; jp_min=200; aws_min=50
  fi
  {
    echo '#!/bin/bash'
    echo "# ipset の集合 port_guard_jp${s}・port_guard_allow${s}・port_guard_aws${s} の中身を入れ替え、起動時に読み込むファイルに保存し直す"
    echo 'set -euo pipefail'
    echo "echo \"== \$(hostname) \$(date '+%F %T') refresh-${family}\""
    echo
    echo '# 今の集合があることを確かめる（1 つでもなければ、どれも入れ替えずに止まる）'
    for set in jp allow aws; do echo "sudo -n ipset list -t port_guard_${set}${s} > /dev/null"; done
    echo
    echo '# 一時の集合を作る（前回の途中で残っていれば、先に消す）'
    for set in jp allow aws; do
      echo "sudo -n ipset destroy port_guard_${set}${s}_new 2>/dev/null || true"
      echo "sudo -n ipset create port_guard_${set}${s}_new hash:net family ${inet} maxelem 65536"
    done
    echo
    echo '# 一時の集合に、新しい一覧を入れる'
    echo "sudo -n ipset restore -exist <<'EOF'"
    for set in jp allow aws; do
      awk -v set="port_guard_${set}${s}_new" '{ print "add " set " " $1 }' "$LAST/$set-$family.new"
    done
    echo 'EOF'
    echo
    echo '# 件数を確かめる（足りなければ、今の集合に触らずに止まる）'
    echo "[ \"\$(sudo -n ipset list -t port_guard_jp${s}_new | awk -F': ' '/Number of entries/ { print \$2 }')\" -ge ${jp_min} ] || { echo \"日本の範囲が ${jp_min} 件未満なので止める\"; exit 1; }"
    echo "[ \"\$(sudo -n ipset list -t port_guard_aws${s}_new | awk -F': ' '/Number of entries/ { print \$2 }')\" -ge ${aws_min} ] || { echo \"AWS の範囲が ${aws_min} 件未満なので止める\"; exit 1; }"
    echo
    echo '# 今の集合と一時の集合を、一瞬で入れ替える（iptables のルールには触らない）'
    for set in jp allow aws; do echo "sudo -n ipset swap port_guard_${set}${s}_new port_guard_${set}${s}"; done
    echo
    echo '# 一時の集合（入れ替えた後は古い中身）を消す'
    for set in jp allow aws; do echo "sudo -n ipset destroy port_guard_${set}${s}_new"; done
    echo
    echo '# 起動時に読み込むファイルを、別名で作ってから置き換える（途中で失敗しても、今のファイルは壊れない）'
    echo 'sudo -n install -d -m 755 /etc/port-guard'
    echo "sudo -n sh -c 'ipset save port_guard_jp${s} > /etc/port-guard/ipset-${family}.save.new && ipset save port_guard_allow${s} >> /etc/port-guard/ipset-${family}.save.new && ipset save port_guard_aws${s} >> /etc/port-guard/ipset-${family}.save.new && mv /etc/port-guard/ipset-${family}.save.new /etc/port-guard/ipset-${family}.save'"
    echo
    echo '# 確認'
    for set in jp allow aws; do echo "sudo -n ipset list -t port_guard_${set}${s} | grep -E '^(Name|Number of entries|References):'"; done
  } > "command/port_guard/refresh-${family}.sh"
done

# 3. 今回の一覧を、次の比較のために残す
for name in jp-ipv4 jp-ipv6 aws-ipv4 aws-ipv6 allow-ipv4 allow-ipv6; do
  mv "$LAST/$name.new" "$LAST/$name.txt"
done
echo "作った: command/port_guard/refresh-ipv4.sh（$(wc -l < command/port_guard/refresh-ipv4.sh | tr -d ' ') 行）、command/port_guard/refresh-ipv6.sh（$(wc -l < command/port_guard/refresh-ipv6.sh | tr -d ' ') 行）"
