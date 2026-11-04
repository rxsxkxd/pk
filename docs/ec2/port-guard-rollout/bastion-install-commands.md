# 踏み台サーバーから入れる: iptables・ipset のインストールと設定のコマンド

> 位置付け: 踏み台サーバーから SSH で、対象のサーバーに iptables ＋ ipset（80・443 番を日本の IP の範囲と許可する IP だけにする）を**入れて設定する**ためのコマンドを、ステップごとの `operation.sh` の形でまとめたもの。どのステップも、**上から順に実行するコマンドを並べただけ**（関数や、条件で分ける処理は使わない）。複数台に当て込むのは、踏み台サーバーにある今のスクリプトで行う。iptables・ipset そのものは [iptables と ipset の基本](./iptables-ipset-basics.md)、仕組みは [iptables ＋ ipset の仕組みと確認](./iptables-ipset.md)。
>
> 状態: 対象のサーバー（AL2）ではまだ流していない。手元（macOS）での確認は「[確かめたこと](#確かめたこと)」。
>
> 更新日: 2026-11-04

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
| 5 | 対象のサーバー | `command/05-persist-ipv4.sh`（`-ipv6.sh`） | 集合を保存し、起動時に集合とルールを入れ直す行を、ユニットの追加の設定（ドロップイン）として置く | まだ効かない（ステップ 6 で有効にする） |
| 6 | 対象のサーバー | `command/06-service.sh` | IPv4・IPv6 で 1 つのユニット `port-guard.service` を置いて有効にする | 再起動の後も効く |

各ステップの結果（`result.txt`）を見てから、次のステップを流す。

### 注意: ステップ 6 の前に再起動したら、ステップ 2 から流し直す

ステップ 6（ユニットを置いて有効にする）を流す前に対象のサーバーを再起動すると、**集合もルールも消えて、80・443 番の遮断も外れる**。ステップ 6 まで流してあれば、起動時にユニットが入れ直すので、流し直しは要らない。

| もの | 再起動の後 |
|---|---|
| ipset の集合（ステップ 2・3） | **消える**（カーネルの中にしかない） |
| iptables・ip6tables のルール（ステップ 4） | **消える**（同じくカーネルの中） |
| ipset のパッケージ（ステップ 1） | 残る |
| 保存のファイルと追加の設定（ステップ 5） | 残る（ただし、ステップ 6 がないと起動時には使われない） |
| 踏み台サーバーの一覧（ステップ 0）と、ステップ 3 のファイル | 残る |

流し直す順番（IPv6 も絞る台は、IPv6 の分も）:

1. `02-sets-ipv4.sh`（空の集合を作る）
2. `03-jp-ipv4.sh`・`03-allow-ipv4.sh`（集合に一覧を入れる。前に作ったファイルをそのまま使える。ステップ 0 と、ステップ 3 のファイルの作り直しは、一覧を新しくしたいときだけ）
3. `04-rules-ipv4.sh`（ルールを入れる。ここで遮断が効く）
4. 再起動の後も残すなら、`05-persist-ipv4.sh` と `06-service.sh`

ステップ 2 と 3 は飛ばせない。ステップ 4 のルールは集合を名前で参照するので、集合がないとルールを入れられずに失敗する。また、ステップ 4 は日本の集合が 1,000 件（IPv6 は 200 件）未満だと止まる。

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
| `iptables -V` | `v1.6` 以上であること（ステップ 4 以降の `-w 10`（秒数を付けたロック待ち）が使える。AL2 は 1.8 系の見込み）。`legacy` と出るのが AL2 の普通の形 |
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

**ここから遮断が効く**。80・443 番は、日本の範囲と許可する IP からだけ受け付ける。22 番は絞らないので、踏み台サーバーからの SSH は今までどおり入れる。**この時点では、再起動するとルールも集合も消える**（ステップ 5・6 で残す。その前に再起動したら、[ステップ 2 から流し直す](#注意-ステップ-6-の前に再起動したらステップ-2-から流し直す)）。

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

sudo -n iptables -w 10 -N PORT_GUARD
sudo -n iptables -w 10 -A PORT_GUARD -i lo -j ACCEPT
sudo -n iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
sudo -n iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
sudo -n iptables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
sudo -n iptables -w 10 -A PORT_GUARD -j DROP
sudo -n iptables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

# 確認
sudo -n iptables -w 10 -S PORT_GUARD
sudo -n iptables -w 10 -S INPUT | grep -- '-j PORT_GUARD'
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

sudo -n ip6tables -w 10 -N PORT_GUARD
sudo -n ip6tables -w 10 -A PORT_GUARD -i lo -j ACCEPT
sudo -n ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow6 src -j ACCEPT
sudo -n ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp6 src -j ACCEPT
sudo -n ip6tables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
sudo -n ip6tables -w 10 -A PORT_GUARD -j DROP
sudo -n ip6tables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

# 確認
sudo -n ip6tables -w 10 -S PORT_GUARD
sudo -n ip6tables -w 10 -S INPUT | grep -- '-j PORT_GUARD'
```

| 行 | 意味 |
|---|---|
| `-w 10` | ほかのものが iptables を操作している間は、終わるまで最大 10 秒待つ。`iptables` と `ip6tables` は同じロック（`/run/xtables.lock`）を使うので、付けないと、同じ時刻に動いたほうが `Another app is currently holding the xtables lock` で失敗する。どの `iptables`・`ip6tables` にも付ける。1 回のコマンドがロックを持つのは一瞬なので、普通は待ってもすぐ空く。10 秒たっても空かなければ失敗して、`set -e` でそこで止まる（秒数なしの `-w` は空くまで待ち続けるので、止まったまま気付かないことがある）。秒数を付けた形は iptables 1.6 以上（ステップ 1 の `iptables -V`） |
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
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
```

チェーンも消して、ステップ 4 を流し直せる状態に戻すなら、続けて `sudo -n iptables -w 10 -F PORT_GUARD` と `sudo -n iptables -w 10 -X PORT_GUARD`。

## 5. 再起動の後に入れ直す行を置く（`command/05-persist-ipv4.sh`・`05-persist-ipv6.sh`）

iptables のルールと ipset の集合は、カーネルの中にしかないので、再起動すると消える。起動時に入れ直すのは、ステップ 6 で置く **1 つのユニット `port-guard.service`** で、IPv4 と IPv6 の分は、このステップで**ユニットの追加の設定（ドロップイン）として別々のファイルに置く**。

| ファイル（対象のサーバー） | 置くステップ | 中身 |
|---|---|---|
| `/etc/port-guard/ipset-ipv4.save` | 5（IPv4） | IPv4 の集合を `ipset save` で保存したもの |
| `/etc/systemd/system/port-guard.service.d/10-ipv4.conf` | 5（IPv4） | 起動時に IPv4 の集合を読み込み、ステップ 4 と同じルールを入れる `ExecStart=` の並び |
| `/etc/port-guard/ipset-ipv6.save` | 5（IPv6） | IPv6 の集合を保存したもの |
| `/etc/systemd/system/port-guard.service.d/20-ipv6.conf` | 5（IPv6） | IPv6 の分の `ExecStart=` の並び |
| `/etc/systemd/system/port-guard.service` | 6 | 本体。`ExecStart=` は持たない（上の 2 つから集まる） |

systemd は、ユニットを読むときに `port-guard.service.d/` の `*.conf` を名前の順に読み、`ExecStart=` を本体に足していく。そのため、

- **IPv4・IPv6 のどちらも、入れるかどうかを選べる**: 置いたファイルの分だけが動く。IPv6 を絞らない台では `05-persist-ipv6.sh` を流さない。後から外すときは、そのファイルを消して `systemctl daemon-reload` するだけ
- **IPv4 → IPv6 の順に、1 つずつ動く**: `10-` が `20-` より先に読まれる。1 つのユニットの `ExecStart=` は上から順に 1 つずつ動くので、IPv4 と IPv6 が同じ時刻に iptables を操作することがない（2 つのユニットに分けると、systemd が並べて起動して、ロックを取り合う）
- ステップ 1〜5 は IPv4・IPv6 で別のファイルのまま。まとまるのはユニットだけ

ステップ 4 を確かめてから流す。

`command/05-persist-ipv4.sh`:

```bash
#!/bin/bash
# IPv4 の集合を保存し、起動時に IPv4 の集合とルールを入れ直す行をユニットの追加の設定として置く
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 05-persist-ipv4"

sudo -n install -d -m 755 /etc/port-guard
sudo -n sh -c 'ipset save port_guard_jp > /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_allow >> /etc/port-guard/ipset-ipv4.save'

sudo -n install -d -m 755 /etc/systemd/system/port-guard.service.d
sudo -n tee /etc/systemd/system/port-guard.service.d/10-ipv4.conf > /dev/null <<'EOF'
# IPv4: 保存した集合を読み込み、ステップ 4 と同じルールを入れる
[Service]
ExecStart=/usr/sbin/ipset restore -exist -file /etc/port-guard/ipset-ipv4.save
ExecStart=-/usr/sbin/iptables -w 10 -N PORT_GUARD
ExecStart=/usr/sbin/iptables -w 10 -F PORT_GUARD
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -i lo -j ACCEPT
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -j DROP
ExecStart=-/usr/sbin/iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
ExecStart=/usr/sbin/iptables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD
EOF

sudo -n systemctl daemon-reload

# 確認
head -3 /etc/port-guard/ipset-ipv4.save
grep -c '^add port_guard_jp ' /etc/port-guard/ipset-ipv4.save || true    # 日本の範囲の件数（0 件のとき grep は失敗を返すので || true）
grep -c '^add port_guard_allow ' /etc/port-guard/ipset-ipv4.save || true # 許可する IP の件数
grep -c '^ExecStart=' /etc/systemd/system/port-guard.service.d/10-ipv4.conf   # 10
```

`command/05-persist-ipv6.sh`（IPv6 も絞るときだけ）:

```bash
#!/bin/bash
# IPv6 の集合を保存し、起動時に IPv6 の集合とルールを入れ直す行をユニットの追加の設定として置く
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 05-persist-ipv6"

sudo -n install -d -m 755 /etc/port-guard
sudo -n sh -c 'ipset save port_guard_jp6 > /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_allow6 >> /etc/port-guard/ipset-ipv6.save'

sudo -n install -d -m 755 /etc/systemd/system/port-guard.service.d
sudo -n tee /etc/systemd/system/port-guard.service.d/20-ipv6.conf > /dev/null <<'EOF'
# IPv6: 保存した集合を読み込み、ステップ 4 と同じルールを入れる
[Service]
ExecStart=/usr/sbin/ipset restore -exist -file /etc/port-guard/ipset-ipv6.save
ExecStart=-/usr/sbin/ip6tables -w 10 -N PORT_GUARD
ExecStart=/usr/sbin/ip6tables -w 10 -F PORT_GUARD
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -i lo -j ACCEPT
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow6 src -j ACCEPT
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp6 src -j ACCEPT
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -j DROP
ExecStart=-/usr/sbin/ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
ExecStart=/usr/sbin/ip6tables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD
EOF

sudo -n systemctl daemon-reload

# 確認
head -3 /etc/port-guard/ipset-ipv6.save
grep -c '^add port_guard_jp6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_allow6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^ExecStart=' /etc/systemd/system/port-guard.service.d/20-ipv6.conf   # 10
```

| 行 | 意味 |
|---|---|
| `ipset save <集合>` | 集合を作る行（`create ...`）と、中身の行（`add ...`）を書き出す。起動時に `ipset restore -file` で読み込む |
| `ipset restore -exist` | 集合や中身がすでにあっても失敗しない |
| `ExecStart=-...` の `-` | その行が失敗しても、次の行へ進む。`-N` は「チェーンがすでにある」とき、`-D` は「INPUT からの 1 行がまだない」ときに失敗するので、どちらも `-` を付けている |
| `-F PORT_GUARD` | チェーンの中身を空にしてから、5 つのルールを入れ直す（二重に入らない） |
| `-D INPUT ...` の後に `-I INPUT 1 ...` | INPUT からの 1 行を消してから入れ直す（二重に入らない） |
| `-w 10` | ロックが空くまで最大 10 秒待つ（ステップ 4 の表）。起動時に iptables を操作するほかのもの（Docker など）とも、取り合いで失敗しない。10 秒で空かなければ、その行で止まってユニットは `failed` になる（`journalctl -b -u port-guard` で分かる） |
| `systemctl daemon-reload` | systemd に、置いたファイルを読み直させる |

`-`・`-F`・`-D` で、**このユニットは何度流しても同じ状態になる**（起動時に何かが先にチェーンを作っていても、動いている OS の上で `start`・`restart` しても失敗しない）。ただし、動いている OS の上で流し直すと、`-F` から `DROP` を入れ直すまでの一瞬、80・443 番が素通りになる（起動時は、ネットワークがつながる前に流れるので関係ない）。

## 6. ユニットを置いて有効にする（`command/06-service.sh`）

ユニットの本体を置いて、起動時に動くようにする。ステップ 5 を（IPv4 だけ、または IPv4 と IPv6）流した後に流す。

`command/06-service.sh`:

```bash
#!/bin/bash
# IPv4・IPv6 で 1 つのユニットを置いて有効にする（ExecStart= はステップ 5 の追加の設定から集まる）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 06-service"

sudo -n tee /etc/systemd/system/port-guard.service > /dev/null <<'EOF'
[Unit]
Description=port-guard: accept 80/443 only from Japan and allowed addresses (IPv4 and IPv6)
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
# ExecStart= は port-guard.service.d/10-ipv4.conf・20-ipv6.conf にある（置いた分だけ動く）

[Install]
WantedBy=multi-user.target
EOF

sudo -n systemctl daemon-reload
sudo -n systemctl enable port-guard

# 確認
ls /etc/systemd/system/port-guard.service.d/        # 10-ipv4.conf（と 20-ipv6.conf）
systemctl cat port-guard | grep -c '^ExecStart='      # 10（IPv4 だけ）か 20（IPv4 と IPv6）。本体と追加の設定をまとめて表示する
systemctl is-enabled port-guard                      # enabled
```

| 点 | 内容 |
|---|---|
| `Type=oneshot` | `ExecStart=` を上から順に 1 つずつ実行して終わる（常駐しない）。どれかが失敗すると（`-` の付いた行を除く）、そこで止まり、ユニットは `failed` になる。IPv4 の行が先なので、IPv6 の行で失敗しても、IPv4 の遮断は入っている |
| `RemainAfterExit=yes` | 実行が終わっても `active` と表示する（入れたことが `systemctl is-active` で分かる） |
| `Before=network-pre.target` | ネットワークがつながる前に入れる（起動の途中に、遮断していない時間ができない） |
| `enable` だけで `start` はしない | ルールはステップ 4 ですでに入っているので、今 `start` する必要はない（流しても失敗はしないが、上の一瞬の素通りがある） |
| 本体に `ExecStart=` がない | ステップ 5 の追加の設定が 1 つもないと、systemd は「`ExecStart=` がない」としてこのユニットを読み込まない。ステップ 5 を先に流す |
| `/usr/sbin/ipset` などの場所 | ステップ 1 の `command -v` の結果と同じであること |
| 一覧を入れ替えたら | ステップ 3 を流した後に、ステップ 5 の `ipset save` の 2 行も流し直す（流し直さないと、再起動のときに古い一覧に戻る） |
| 再起動の後に確かめる | 保守の時間帯に再起動して、ステップ 4 の「確認」の 2 行（IPv6 も入れたなら `ip6tables` でも）と `systemctl is-active port-guard`（`active`）、`journalctl -b -u port-guard`（起動時の記録） |

### IPv4・IPv6 を後から外す・足す

| したいこと | すること |
|---|---|
| IPv6 を起動時に入れないようにする | `sudo -n rm /etc/systemd/system/port-guard.service.d/20-ipv6.conf` と `sudo -n systemctl daemon-reload`（今入っている IPv6 のルールは、ステップ 4 の「外す」で外す） |
| IPv6 を後から足す | IPv6 のステップ 2〜4 の後に `05-persist-ipv6.sh` を流す（ステップ 6 は流し直さなくてよい） |

### 前の形（IPv4・IPv6 で 2 つのユニット）で入れた台

前の版のこのドキュメントでは、IPv4 を `port-guard.service`、IPv6 を `port-guard6.service` に分けていた。2 つは順番の指定がないので、起動時に同時に動いてロックを取り合い、片方が失敗することがある。また `-N PORT_GUARD` で始まるので、チェーンがすでにあると失敗する。次を流してから、ステップ 5・6 を流し直す（本体の `port-guard.service` はステップ 6 で上書きされる）。

`command/06-migrate.sh`:

```bash
#!/bin/bash
# 前の形の IPv6 のユニット（port-guard6.service）を止めて消す
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 06-migrate"
sudo -n systemctl disable port-guard6 || true      # すでに外していれば失敗するので || true
sudo -n rm -f /etc/systemd/system/port-guard6.service
sudo -n systemctl daemon-reload
ls /etc/systemd/system/ | grep port-guard || true   # port-guard.service（と port-guard.service.d）だけになっていること
```

## 確かめたこと

手元（macOS）で、2026-11-02 に確かめた（ステップ 4〜6 は 2026-11-04 に確かめ直した）。対象のサーバー（AL2）では、まだ流していない。

| 確かめたこと | 結果 |
|---|---|
| ステップ 0 を、実際の APNIC の統計で流す | IPv4 4,738 件・IPv6 766 件。IPv4 は全件が Python の `ipaddress` の変換と一致、IPv6 は全件が正しい CIDR として読める（[サンプル](./samples/apnic-jp-20261102/README.md)）。`1.0.16.1` は入り、`8.8.8.8` は入らない |
| ステップ 3 の 1 行ずつで作るファイル | `add <集合> <範囲>` の行が一覧の件数と同じだけ並ぶ。コメントと空の行は除かれる |
| ステップ 1〜5 を `bash < ファイル` の形（標準入力で送る形）で、IPv4・IPv6 とも順に流す | 最後まで流れる。`sudo`・`ipset`・`iptables`・`systemctl` などは、呼ばれ方と状態（集合の件数、チェーンがあるか）を覚えるだけの偽物に置き換え、`/etc` などは作業用のフォルダに読み替えた。集合の件数（4,738・766・許可する IP の件数）、ステップ 4 のルールの並び（チェーンの 6 行と `INPUT` の 1 行）、保存のファイルの件数、追加の設定の `ExecStart=` の 10 行（IPv4・IPv6 それぞれ）と、`systemctl cat` で集まる 20 行が、どれも狙いどおり |
| 止まるべきときに止まるか | ステップ 4 をもう一度流すと `-N PORT_GUARD` で止まる（二重に入れない）。日本の集合が空なら、ルールを入れずに止まる |
| ユニットを何度流しても同じ状態になるか | 追加の設定の `ExecStart=` を、systemd と同じ扱い（上から順、`-` の行は失敗しても進む）で流す偽物で確かめた。ステップ 4 の後（チェーンがある状態）で 2 回、起動直後と同じ状態（チェーンがない）で 2 回流して、どれもチェーンの 5 行と `INPUT` の 1 行だけになる（二重に入らない） |
| AL2 の上で起きた誤り（2026-11-04） | 前の形（IPv4・IPv6 で 2 つのユニット、`-w` なし、`-N` で始まる）で、起動時に `Another app is currently holding the xtables lock` と `iptables: Chain already exists.` が出た。前者は 2 つのユニットが同時に動いてロックを取り合ったため、後者はチェーンがすでにある状態でユニットが流れたため（何がチェーンを先に作ったかは未確認）。1 つのユニット・`-w 10`・何度流しても同じ状態になる書き方に直した |
| 見つけて直した誤り | 許可する IP が 0 件のとき、ステップ 5 の確認の `grep -c` が失敗を返して、`set -e` でそこで止まっていた（`|| true` を付けた） |
| 構文 | どのファイルも `bash -n` で通る（手元の bash 3.2。AL2 は bash 4.2） |

AL2 の上で確かめたいこと: `ipset restore` と `ipset save` の実際の動き、追加の設定の `ExecStart=` が本体に集まって、起動時に IPv4 → IPv6 の順に通るか（`systemctl cat port-guard` と `journalctl -b -u port-guard`）（`Before=network-pre.target` で、`ipset` のモジュールが読み込めるか）、標準入力で約 160 KB（ステップ 3 の IPv4 のファイル）を送れるか。

## 道具（py/・sh/・rb/）との違い

| 項目 | 道具 | このドキュメント |
|---|---|---|
| 入り方 | SSM の Run Command（Python 版は SSH も） | 踏み台サーバーからの SSH |
| 書き方 | 適用のスクリプト（`port-guard-apply`）が、一覧のファイル（`jp.txt`・`allow.txt`）から集合とルールを作る | ステップごとに、実行するコマンドを並べただけ |
| 日本の範囲の取得 | 対象のサーバーで `curl` と `python3`（`port-guard-update-jp`） | 踏み台サーバーで `curl` と `awk` |
| 再起動の後に残す | ユニットが `port-guard-apply` を呼ぶ | 1 つのユニット `port-guard.service` に、IPv4・IPv6 の追加の設定（`10-ipv4.conf`・`20-ipv6.conf`）から、保存した集合の読み込みとルールのコマンドが集まる |
| IPv6 | 絞らない | `*-ipv6.sh` を流せば絞れる |
| 入れる前の確認 | 道具が既存のルール・既存の集合などを見て、問題があれば入れない | ステップ 1 の確認の行を見て、作業者が判断する |
| 有効にするとき | 自動で元に戻る予約を入れてから有効にし、確かめて確定する | 予約は入れない（22 番は絞らないので、SSH で入って外せる） |

対象のサーバーのファイルの置き方が違うので、[運用の手順](./operations.md) の `port-guard-apply`・`port-guard-update-jp` を使う手順は、このドキュメントで入れた台には当てはまらない（一覧の入れ替えは、ステップ 0・3 と、ステップ 5 の `ipset save` の 2 行を流し直す）。
