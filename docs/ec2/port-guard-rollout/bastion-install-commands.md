# 踏み台サーバーから入れる: iptables・ipset のインストールと設定のコマンド

> 位置付け: 踏み台サーバーから SSH で、対象のサーバーに iptables ＋ ipset（80・443 番を日本の IP の範囲と許可する IP だけにする）を**入れて設定する**ためのコマンドを、ステップごとの `operation.sh` の形でまとめたもの。どのステップも、**上から順に実行するコマンドを並べただけ**（関数や、条件で分ける処理は使わない）。複数台に当て込むのは、踏み台サーバーにある今のスクリプトで行う。iptables・ipset そのものは [iptables と ipset の基本](./iptables-ipset-basics.md)、仕組みは [iptables ＋ ipset の仕組みと確認](./iptables-ipset.md)。
>
> 状態: 対象のサーバー（AL2）ではまだ流していない。手元（macOS）での確認は「[確かめたこと](#確かめたこと)」。
>
> 更新日: 2026-11-02

## この形の前提

| 項目 | 内容 |
|---|---|
| 流し方 | 踏み台サーバーで `ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/<ステップ>.sh >> ./output/result.txt`。複数台へは、今の当て込みのスクリプトで |
| 日本の範囲の一覧 | **踏み台サーバーで作る**（IPv4 と IPv6）。対象のサーバーは APNIC に取りに行かない（`curl`・`python3` は要らない） |
| 一覧の渡し方 | 一覧は、ステップ 3 のファイルの中に `ipset` の行（`add <集合> <範囲>`）として並べて送る。そのファイルは踏み台サーバーで、一覧から 1 行のコマンドで作る |
| 実行する人 | `centos`。root が要る操作は `sudo -n`（パスワードを聞かれる設定なら、待たずに失敗する） |
| 絞るポート | 80・443 番（22 番は絞らない。踏み台からの SSH は今までどおり入れる） |
| IPv6 | 対象のサーバーに IPv6 のアドレスがあり、セキュリティグループで IPv6 を通しているときだけ要る。**IPv6 の分は、どのステップも別のファイル**（`*-ipv6.sh`）にしているので、IPv6 を絞らないなら流さない |

### IPv4 と IPv6 は、ファイルも集合も分ける

| 種類 | 踏み台サーバーの一覧 | ipset の集合 | 再起動のために保存するファイル（対象のサーバー） |
|---|---|---|---|
| 日本の範囲（IPv4） | `lists/jp-ipv4.txt` | `port_guard_jp`（`hash:net family inet`） | `/etc/port-guard/ipset-ipv4.save` |
| 許可する IP（IPv4） | `lists/allow-ipv4.txt` | `port_guard_allow`（`hash:net family inet`） | `/etc/port-guard/ipset-ipv4.save` |
| 日本の範囲（IPv6） | `lists/jp-ipv6.txt` | `port_guard_jp6`（`hash:net family inet6`） | `/etc/port-guard/ipset-ipv6.save` |
| 許可する IP（IPv6） | `lists/allow-ipv6.txt` | `port_guard_allow6`（`hash:net family inet6`） | `/etc/port-guard/ipset-ipv6.save` |

ipset の 1 つの集合には、IPv4 か IPv6 のどちらかしか入らない（`family`）。iptables は IPv4 の集合を、ip6tables は IPv6 の集合を参照する。集合の名前は道具（`py/`・`sh/`・`rb/`）と同じにしている。

2026-11-02 の版で作った一覧のサンプル（Python で作ったもの。ステップ 0 の `awk` の結果と同じ）は [`samples/apnic-jp-20261102/`](./samples/apnic-jp-20261102/README.md) に置いている。

### 標準入力で送るときの注意

`bash` はスクリプトを標準入力から少しずつ読みながら実行する。そのため、**スクリプトの中で標準入力を読むコマンドを使うと、残りのスクリプトを読み込んでしまう**（そこから後が実行されない）。

- 標準入力を読むかもしれないコマンドには `< /dev/null` を付ける（このドキュメントでは `yum` に付けている）
- ヒアドキュメント（`<<'EOF'` から `EOF` まで）は、スクリプトの一部として読まれる。`ipset restore` や `tee` に渡す中身はこの形で書いている
- エラーの出力も結果のファイルに残すなら、`>> ./output/result.txt 2>&1` にする

### ステップの一覧

| ステップ | どこで | ファイル | すること | この後に効くか |
|---|---|---|---|---|
| 0 | 踏み台サーバー | `make-jp-lists.sh` | APNIC の統計から、日本の IPv4・IPv6 の範囲の一覧を作る | — |
| 1 | 対象のサーバー | `command/01-install.sh` | ipset を入れる（iptables は最初から入っている） | 効かない |
| 2 | 対象のサーバー | `command/02-sets-ipv4.sh`（`-ipv6.sh`） | 空の集合を作る | 効かない |
| 3 | 踏み台で作り、対象のサーバーで流す | `command/03-jp-ipv4.sh`・`03-allow-ipv4.sh`（`-ipv6.sh`） | 集合に一覧を入れる | 効かない（集合はルールから参照されるまで何もしない） |
| 4 | 対象のサーバー | `command/04-rules-ipv4.sh`（`-ipv6.sh`） | iptables のルールを入れる | **ここから遮断が効く**（再起動すると消える） |
| 5 | 対象のサーバー | `command/05-persist-ipv4.sh`（`-ipv6.sh`） | 集合を保存し、起動時に集合とルールを入れ直すユニットを置いて有効にする | 再起動の後も効く |

各ステップの結果（`result.txt`）を見てから、次のステップを流す。

## 0. 日本の範囲の一覧を作る（踏み台サーバー）

APNIC の割り当ての統計（無料、登録なし、毎日更新）から、日本（`JP`）に割り当てられた範囲を取り出す。IPv4 は「先頭のアドレスと個数」で書かれているので CIDR に分ける（個数は 2 のべき乗とは限らない）。IPv6 は「先頭のアドレスと長さ」で書かれているので、そのまま CIDR になる。`awk` だけで行うので、踏み台に Python は要らない。

`make-jp-lists.sh`:

```bash
#!/bin/bash
# 踏み台サーバーで実行する。APNIC の割り当ての統計から、日本の IPv4・IPv6 の範囲の一覧を lists/ に作る
set -euo pipefail
mkdir -p lists
curl -fsS --max-time 120 -o lists/delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest

# IPv4: 先頭のアドレスと個数を、CIDR に分ける
awk -F'|' '
function ip2n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
function n2ip(n) { return sprintf("%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256) }
$2 == "JP" && $3 == "ipv4" && ($7 == "allocated" || $7 == "assigned") {
  start = ip2n($4); count = $5
  while (count > 0) {
    size = 1; bits = 32
    while (size * 2 <= count && start % (size * 2) == 0) { size *= 2; bits-- }
    print n2ip(start) "/" bits
    start += size; count -= size
  }
}' lists/delegated-apnic-latest > lists/jp-ipv4.txt

# IPv6: 先頭のアドレスと長さを、そのまま CIDR にする
awk -F'|' '$2 == "JP" && $3 == "ipv6" && ($7 == "allocated" || $7 == "assigned") { print $4 "/" $5 }' \
  lists/delegated-apnic-latest > lists/jp-ipv6.txt

echo "IPv4: $(wc -l < lists/jp-ipv4.txt) 件、IPv6: $(wc -l < lists/jp-ipv6.txt) 件"
```

| 点 | 内容 |
|---|---|
| 件数の目安 | 2026-11-02 の時点で IPv4 4,738 件、IPv6 766 件。ステップ 4 は、日本の集合がこの 5 分の 1（IPv4 1,000 件・IPv6 200 件）より少なければ止まる。件数が大きく変わったら見直す |
| 取得に失敗したとき | `curl` が失敗すれば、そこで止まる（`set -e`）。前回の `lists/` はそのまま残る |
| 許可する IP の一覧 | 踏み台サーバーに `lists/allow-ipv4.txt`（と、IPv6 も絞るなら `lists/allow-ipv6.txt`）を置く。1 行 1 件、CIDR 可、`#` から後はコメント。日本以外から受ける必要がある相手（海外の拠点、外部サービス、監視など）を書く。なければ空のファイル |

## 1. ipset を入れる（`command/01-install.sh`）

```bash
#!/bin/bash
# ipset を入れる（iptables は最初から入っている）。iptables-services は入れない・使わない
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 01-install"

sudo -n yum install -y -q ipset < /dev/null

# 確認
rpm -q iptables ipset
iptables -V
sudo -n ipset version
command -v ipset iptables ip6tables                                  # /usr/sbin/... の場所（ステップ 5 のユニットに書く）
systemctl is-enabled iptables ip6tables ipset 2>&1 | paste -sd' ' -   # どれも enabled でないこと
systemctl is-active iptables ip6tables ipset 2>&1 | paste -sd' ' -    # どれも active でないこと
```

| 結果の見方 | 内容 |
|---|---|
| `ipset version` | 版が出れば入っている |
| `command -v` | `/usr/sbin/ipset`・`/usr/sbin/iptables`・`/usr/sbin/ip6tables` であること（違えば、ステップ 5 のユニットの `ExecStart=` の場所を直す） |
| `iptables`・`ip6tables`・`ipset` のユニット | どれも `enabled`・`active` でないこと。`enabled` なら、次の再起動で動き出して、このあと入れるルールを置き換える（`iptables` のユニットの既定の設定は、SSH 以外の受信を拒否する）。見つかったら、その台は先へ進めずに理由を調べる |

ipset に要るカーネルのモジュール（`ip_set`・`xt_set`）は、集合を作ったときや、ルールから参照したときに自動で読み込まれる。再起動は要らない。

## 2. 空の集合を作る（`command/02-sets-ipv4.sh`・`02-sets-ipv6.sh`）

集合を作るだけ。**まだ何も効かない**。

`command/02-sets-ipv4.sh`:

```bash
#!/bin/bash
# IPv4 の空の集合を作る（日本の範囲と、許可する IP）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 02-sets-ipv4"

sudo -n ipset create -exist port_guard_jp hash:net family inet maxelem 65536
sudo -n ipset create -exist port_guard_allow hash:net family inet maxelem 65536

# 確認
sudo -n ipset list -t port_guard_jp
sudo -n ipset list -t port_guard_allow
```

`command/02-sets-ipv6.sh`（IPv6 も絞るときだけ）:

```bash
#!/bin/bash
# IPv6 の空の集合を作る（日本の範囲と、許可する IP）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 02-sets-ipv6"

sudo -n ipset create -exist port_guard_jp6 hash:net family inet6 maxelem 65536
sudo -n ipset create -exist port_guard_allow6 hash:net family inet6 maxelem 65536

# 確認
sudo -n ipset list -t port_guard_jp6
sudo -n ipset list -t port_guard_allow6
```

| 指定 | 意味 |
|---|---|
| `-exist` | すでにあっても失敗にしない（もう一度流してもよい） |
| `hash:net` | CIDR（長さはばらばらでよい）を入れる型 |
| `family inet` / `family inet6` | IPv4 用 / IPv6 用 |
| `maxelem 65536` | 入れられる件数の上限（日本の範囲は数千件なので足りる） |

## 3. 集合に一覧を入れる（`command/03-*.sh`。踏み台サーバーで作る）

一覧は件数が多い（IPv4 は約 4,700 件）ので、ファイルは踏み台サーバーで一覧から作る。**作られるファイルの中身は、集合を空にするコマンドと、`ipset restore` に渡す `add <集合> <範囲>` の行を並べたものだけ**。

踏み台サーバーで、次の 1 行ずつで作る（`#` から後のコメントと空の行は除く）。

```bash
mkdir -p command
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' lists/jp-ipv4.txt | awk 'NF { print "add port_guard_jp " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp'; } > command/03-jp-ipv4.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' lists/allow-ipv4.txt | awk 'NF { print "add port_guard_allow " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow'; } > command/03-allow-ipv4.sh

# IPv6 も絞るときだけ
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' lists/jp-ipv6.txt | awk 'NF { print "add port_guard_jp6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp6'; } > command/03-jp-ipv6.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' lists/allow-ipv6.txt | awk 'NF { print "add port_guard_allow6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow6'; } > command/03-allow-ipv6.sh
```

作られる `command/03-jp-ipv4.sh` の中身（途中の行は省略。2026-11-02 の一覧で 4,744 行、約 160 KB）:

```bash
#!/bin/bash
set -euo pipefail
sudo -n ipset flush port_guard_jp
sudo -n ipset restore -exist <<'EOF'
add port_guard_jp 1.0.16.0/20
add port_guard_jp 1.0.64.0/18
add port_guard_jp 1.1.64.0/18
...
EOF
sudo -n ipset list -t port_guard_jp
```

作られる `command/03-allow-ipv4.sh` の中身（許可する IP が 1 件のとき）:

```bash
#!/bin/bash
set -euo pipefail
sudo -n ipset flush port_guard_allow
sudo -n ipset restore -exist <<'EOF'
add port_guard_allow 203.0.113.10
EOF
sudo -n ipset list -t port_guard_allow
```

| 行 | 意味 |
|---|---|
| `ipset flush <集合>` | 集合を空にする（もう一度流したときに、古い中身を残さない） |
| `ipset restore -exist <<'EOF'` 〜 `EOF` | 間の `add` の行をまとめて読み込む（1 件ずつ `ipset add` を呼ぶより、ずっと速い）。`-exist` は、同じ範囲が重なっても失敗にしない |
| `ipset list -t <集合>` | 結果の確認。`Number of entries` が一覧の件数と同じになっていること |

| 点 | 内容 |
|---|---|
| まだ効かない | 集合は、ステップ 4 のルールから参照されるまで何もしない。このステップの後も、80・443 番は今までどおり |
| 入っているかを確かめる | `sudo ipset test port_guard_jp 1.0.16.1`（入っていれば終了コード 0） |
| 一覧を作り直したら | ステップ 0 の後に、上の 1 行ずつでファイルを作り直す |
| 遮断が効いた後に流し直すとき | `flush` してから入れ直すまでの短い間、集合が空になる（日本からの接続も捨てられる）。入れ直した後は、ステップ 5 の保存（`ipset save` の 2 行）も流し直す |

## 4. ルールを入れる（`command/04-rules-ipv4.sh`・`04-rules-ipv6.sh`）

**ここから遮断が効く**。80・443 番は、日本の範囲と許可する IP からだけ受け付ける。22 番は絞らないので、踏み台サーバーからの SSH は今までどおり入れる。この時点では、再起動するとルールも集合も消える（ステップ 5 で残す）。

`command/04-rules-ipv4.sh`:

```bash
#!/bin/bash
# iptables のルールを入れる（ここから IPv4 の 80・443 番の遮断が効く）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 04-rules-ipv4"

# 日本の範囲が入っていなければ止める（空のまま入れると、日本からも受け付けなくなる）
[ "$(sudo -n ipset list -t port_guard_jp | awk -F': ' '/Number of entries/ { print $2 }')" -ge 1000 ] || { echo "日本の範囲が 1000 件未満なので止める"; exit 1; }

# 今のルールを控える（戻すときの手がかり）
sudo -n install -d -m 700 /var/lib/port-guard
sudo -n sh -c "iptables-save > /var/lib/port-guard/iptables-before-$(date +%Y%m%d%H%M%S).txt"

sudo -n iptables -N PORT_GUARD
sudo -n iptables -A PORT_GUARD -i lo -j ACCEPT
sudo -n iptables -A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
sudo -n iptables -A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
sudo -n iptables -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
sudo -n iptables -A PORT_GUARD -j DROP
sudo -n iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

# 確認
sudo -n iptables -S PORT_GUARD
sudo -n iptables -S INPUT | grep -- '-j PORT_GUARD'
```

`command/04-rules-ipv6.sh`（IPv6 も絞るときだけ）:

```bash
#!/bin/bash
# ip6tables のルールを入れる（ここから IPv6 の 80・443 番の遮断が効く）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 04-rules-ipv6"

[ "$(sudo -n ipset list -t port_guard_jp6 | awk -F': ' '/Number of entries/ { print $2 }')" -ge 200 ] || { echo "日本の範囲（IPv6）が 200 件未満なので止める"; exit 1; }

sudo -n install -d -m 700 /var/lib/port-guard
sudo -n sh -c "ip6tables-save > /var/lib/port-guard/ip6tables-before-$(date +%Y%m%d%H%M%S).txt"

sudo -n ip6tables -N PORT_GUARD
sudo -n ip6tables -A PORT_GUARD -i lo -j ACCEPT
sudo -n ip6tables -A PORT_GUARD -m set --match-set port_guard_allow6 src -j ACCEPT
sudo -n ip6tables -A PORT_GUARD -m set --match-set port_guard_jp6 src -j ACCEPT
sudo -n ip6tables -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
sudo -n ip6tables -A PORT_GUARD -j DROP
sudo -n ip6tables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

# 確認
sudo -n ip6tables -S PORT_GUARD
sudo -n ip6tables -S INPUT | grep -- '-j PORT_GUARD'
```

| 行 | 意味 |
|---|---|
| `-N PORT_GUARD` | 自前のチェーンを作る。**すでにあれば失敗して、そこで止まる**（二重に入れない。入れ直すときは、下の「外す」の後に流す） |
| `-A PORT_GUARD -i lo -j ACCEPT` | 同じマシンの中からの接続は通す |
| `--match-set port_guard_allow src -j ACCEPT` | 送り元が許可する IP の集合に入っていれば通す |
| `--match-set port_guard_jp src -j ACCEPT` | 送り元が日本の範囲の集合に入っていれば通す |
| `-m limit ... -j LOG` | 捨てる前に記録する（1 分に 10 件まで。`journalctl -k` で見られる） |
| `-j DROP` | 残りを捨てる（相手には応答を返さない） |
| `-I INPUT 1 ... -j PORT_GUARD` | 80・443 番あての TCP を `PORT_GUARD` へ飛ばす。**この 1 行が入った時点で遮断が効く** |

| 確かめること | どこで | 内容 |
|---|---|---|
| ルールが入ったか | 結果のファイル | `PORT_GUARD` の 6 行（`-N` と 5 つのルール）と、`-A INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD` の 1 行 |
| 日本からつながるか | 踏み台サーバー（日本にあれば） | `curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://<server>/`（`000` 以外なら応答がある）、`curl -sk -o /dev/null -m 5 -w '%{http_code}\n' https://<server>/` |
| 海外から止まるか | 海外の拠点 | 同じ `curl` が `000`（タイムアウト）になる。拠点は [海外からの確認の拠点](./outside-probe.md) |

うまくいかなかったときは、次の 1 行で遮断を外せる（集合とチェーンは残る。IPv6 は `ip6tables` で同じ）。

```bash
#!/bin/bash
# 遮断を外す（INPUT から PORT_GUARD への 1 行を消す）
sudo -n iptables -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
```

チェーンも消して、ステップ 4 を流し直せる状態に戻すなら、続けて `sudo -n iptables -F PORT_GUARD` と `sudo -n iptables -X PORT_GUARD`。

## 5. 再起動の後も残す（`command/05-persist-ipv4.sh`・`05-persist-ipv6.sh`）

iptables のルールと ipset の集合は、カーネルの中にしかないので、再起動すると消える。ここでは次の 2 つを置く。

- 今の集合の中身を、`ipset save` でファイルに保存する
- 起動時に、保存した集合を読み込み、ステップ 4 と同じルールを入れる systemd のユニット。中身は、ステップ 4 のコマンドを `ExecStart=` に並べたもの

ステップ 4 を確かめてから流す。

`command/05-persist-ipv4.sh`:

```bash
#!/bin/bash
# IPv4 の集合を保存し、起動時に集合とルールを入れ直すユニットを置いて有効にする
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 05-persist-ipv4"

sudo -n install -d -m 755 /etc/port-guard
sudo -n sh -c 'ipset save port_guard_jp > /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_allow >> /etc/port-guard/ipset-ipv4.save'

sudo -n tee /etc/systemd/system/port-guard.service > /dev/null <<'EOF'
[Unit]
Description=port-guard (IPv4): accept 80/443 only from Japan and allowed addresses
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ipset restore -exist -file /etc/port-guard/ipset-ipv4.save
ExecStart=/usr/sbin/iptables -N PORT_GUARD
ExecStart=/usr/sbin/iptables -A PORT_GUARD -i lo -j ACCEPT
ExecStart=/usr/sbin/iptables -A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
ExecStart=/usr/sbin/iptables -A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
ExecStart=/usr/sbin/iptables -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
ExecStart=/usr/sbin/iptables -A PORT_GUARD -j DROP
ExecStart=/usr/sbin/iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

[Install]
WantedBy=multi-user.target
EOF

sudo -n systemctl daemon-reload
sudo -n systemctl enable port-guard

# 確認
head -3 /etc/port-guard/ipset-ipv4.save
grep -c '^add port_guard_jp ' /etc/port-guard/ipset-ipv4.save || true    # 日本の範囲の件数（0 件のとき grep は失敗を返すので || true）
grep -c '^add port_guard_allow ' /etc/port-guard/ipset-ipv4.save || true # 許可する IP の件数
systemctl is-enabled port-guard                                   # enabled
```

`command/05-persist-ipv6.sh`（IPv6 も絞るときだけ）:

```bash
#!/bin/bash
# IPv6 の集合を保存し、起動時に集合とルールを入れ直すユニットを置いて有効にする
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 05-persist-ipv6"

sudo -n install -d -m 755 /etc/port-guard
sudo -n sh -c 'ipset save port_guard_jp6 > /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_allow6 >> /etc/port-guard/ipset-ipv6.save'

sudo -n tee /etc/systemd/system/port-guard6.service > /dev/null <<'EOF'
[Unit]
Description=port-guard (IPv6): accept 80/443 only from Japan and allowed addresses
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ipset restore -exist -file /etc/port-guard/ipset-ipv6.save
ExecStart=/usr/sbin/ip6tables -N PORT_GUARD
ExecStart=/usr/sbin/ip6tables -A PORT_GUARD -i lo -j ACCEPT
ExecStart=/usr/sbin/ip6tables -A PORT_GUARD -m set --match-set port_guard_allow6 src -j ACCEPT
ExecStart=/usr/sbin/ip6tables -A PORT_GUARD -m set --match-set port_guard_jp6 src -j ACCEPT
ExecStart=/usr/sbin/ip6tables -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
ExecStart=/usr/sbin/ip6tables -A PORT_GUARD -j DROP
ExecStart=/usr/sbin/ip6tables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

[Install]
WantedBy=multi-user.target
EOF

sudo -n systemctl daemon-reload
sudo -n systemctl enable port-guard6

# 確認
head -3 /etc/port-guard/ipset-ipv6.save
grep -c '^add port_guard_jp6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_allow6 ' /etc/port-guard/ipset-ipv6.save || true
systemctl is-enabled port-guard6
```

| 点 | 内容 |
|---|---|
| `ipset save <集合>` | 集合を作る行（`create ...`）と、中身の行（`add ...`）を書き出す。起動時に `ipset restore -file` で読み込む |
| ユニットの `ExecStart=` | 上から順に実行される（`Type=oneshot` なので、いくつ並べてもよい）。どれかが失敗すると、そこで止まる |
| `Before=network-pre.target` | ネットワークがつながる前に入れる（起動の途中に、遮断していない時間ができない） |
| **ここでは `enable` だけで、`start` はしない** | ルールはステップ 4 ですでに入っている。今 `start` や `restart` をすると、`-N PORT_GUARD` が「すでにある」で失敗する（ユニットは起動時に 1 回だけ流すもの） |
| 保存のファイルの場所 | ユニットに書く `/usr/sbin/ipset` などの場所は、ステップ 1 の `command -v` の結果と同じであること |
| 一覧を入れ替えたら | ステップ 3 を流した後に、このステップの `ipset save` の 2 行も流し直す（流し直さないと、再起動のときに古い一覧に戻る） |
| 再起動の後に確かめる | 保守の時間帯に再起動して、ステップ 4 の「確認」の 2 行と `systemctl is-active port-guard`（`active`）、`journalctl -b -u port-guard`（起動時の記録） |

## 確かめたこと

手元（macOS）で、2026-11-02 に確かめた。対象のサーバー（AL2）では、まだ流していない。

| 確かめたこと | 結果 |
|---|---|
| ステップ 0 を、実際の APNIC の統計で流す | IPv4 4,738 件・IPv6 766 件。IPv4 は全件が Python の `ipaddress` の変換と一致、IPv6 は全件が正しい CIDR として読める（[サンプル](./samples/apnic-jp-20261102/README.md)）。`1.0.16.1` は入り、`8.8.8.8` は入らない |
| ステップ 3 の 1 行ずつで作るファイル | `add <集合> <範囲>` の行が一覧の件数と同じだけ並ぶ。コメントと空の行は除かれる |
| ステップ 1〜5 を `bash < ファイル` の形（標準入力で送る形）で、IPv4・IPv6 とも順に流す | 最後まで流れる。`sudo`・`ipset`・`iptables`・`systemctl` などは、呼ばれ方と状態（集合の件数、チェーンがあるか）を覚えるだけの偽物に置き換え、`/etc` などは作業用のフォルダに読み替えた。集合の件数（4,738・766・許可する IP の件数）、ステップ 4 のルールの並び（チェーンの 6 行と `INPUT` の 1 行）、保存のファイルの件数、ユニットの `ExecStart=` の 8 行が、どれも狙いどおり |
| 止まるべきときに止まるか | ステップ 4 をもう一度流すと `-N PORT_GUARD` で止まる（二重に入れない）。日本の集合が空なら、ルールを入れずに止まる |
| 見つけて直した誤り | 許可する IP が 0 件のとき、ステップ 5 の確認の `grep -c` が失敗を返して、`set -e` でそこで止まっていた（`|| true` を付けた） |
| 構文 | どのファイルも `bash -n` で通る（手元の bash 3.2。AL2 は bash 4.2） |

AL2 の上で確かめたいこと: `ipset restore` と `ipset save` の実際の動き、ユニットの `ExecStart=` の並びが起動時に通るか（`Before=network-pre.target` で、`ipset` のモジュールが読み込めるか）、標準入力で約 160 KB（ステップ 3 の IPv4 のファイル）を送れるか。

## 道具（py/・sh/・rb/）との違い

| 項目 | 道具 | このドキュメント |
|---|---|---|
| 入り方 | SSM の Run Command（Python 版は SSH も） | 踏み台サーバーからの SSH |
| 書き方 | 適用のスクリプト（`port-guard-apply`）が、一覧のファイル（`jp.txt`・`allow.txt`）から集合とルールを作る | ステップごとに、実行するコマンドを並べただけ |
| 日本の範囲の取得 | 対象のサーバーで `curl` と `python3`（`port-guard-update-jp`） | 踏み台サーバーで `curl` と `awk` |
| 再起動の後に残す | ユニットが `port-guard-apply` を呼ぶ | ユニットが、保存した集合（`ipset-ipv4.save`）を読み込み、ルールのコマンドを並べて実行する |
| IPv6 | 絞らない | `*-ipv6.sh` を流せば絞れる |
| 入れる前の確認 | 道具が既存のルール・既存の集合などを見て、問題があれば入れない | ステップ 1 の確認の行を見て、作業者が判断する |
| 有効にするとき | 自動で元に戻る予約を入れてから有効にし、確かめて確定する | 予約は入れない（22 番は絞らないので、SSH で入って外せる） |

対象のサーバーのファイルの置き方が違うので、[運用の手順](./operations.md) の `port-guard-apply`・`port-guard-update-jp` を使う手順は、このドキュメントで入れた台には当てはまらない（一覧の入れ替えは、ステップ 0・3・5 を流し直す）。
