# 踏み台サーバーから対象のサーバーに iptables と ipset を入れて、80・443 番の受け付けを日本と許可した IP アドレスに絞る手順（コマンドの一覧）

> 位置付け: 踏み台サーバーから SSH で、対象のサーバー（Amazon Linux 2 の Web サーバー）に iptables と ipset の設定を入れるためのコマンドを、ステップごとのファイルにまとめたもの。どのファイルも、**上から順に実行するコマンドを並べただけ**（関数や、条件で分ける処理は使わない）。複数台に流すのは、踏み台サーバーにある今のスクリプトで行う。
>
> このドキュメントは**手順とコマンド、各ステップの説明、結果の見方**を書いている。長い前置き（Linux・iptables・ipset・systemd などを知らない人向けの仕組みの説明）、運用の仕組みの設計（Let's Encrypt の更新・一覧の定期の更新）、手元で確かめたこと、自動化の道具との違いは [補足](./bastion-install-supplement.md) にまとめている。各ステップの説明と、コマンドの 1 行ずつの意味は、このドキュメントの各ステップにある。
>
> 状態: 対象のサーバー（Amazon Linux 2）ではまだ流していない。Let's Encrypt の更新への対応と、一覧の定期の更新は、方針を決めた段階でまだ作っていない（[補足](./bastion-install-supplement.md) の「これから入れる運用の仕組み」）。
>
> 更新日: 2026-11-04

## このドキュメントで行うこと

対象のサーバーが受け付ける **80 番（HTTP）と 443 番（HTTPS）の通信を、次の 2 つから来たものだけ**にする。それ以外から来た 80・443 番の通信は捨てる。**22 番（SSH）は絞らない**。

- 日本に割り当てられた IP アドレス（APNIC が公開している一覧から作る）
- 許可する IP アドレス（**対象のサーバーが入っている VPC の範囲**と、日本の外から受ける必要がある相手）

| 注意 | 内容 |
|---|---|
| **Let's Encrypt の証明書の更新** | certbot で証明書を更新している台は、この手順を入れると、そのままでは更新が失敗する（海外からの確認の接続が捨てられる）。**本番で絞り込みを有効にする前に**、[補足](./bastion-install-supplement.md) の「A. Let's Encrypt の更新の間だけ 80 番を開ける」を入れる（まだ作っていない） |
| **ロードバランサー・CloudFront** | 対象のサーバーが、インターネットから直接 80・443 番を受けていること。前に置くと、この手順では国で絞れない（すべての通信が止まることもある）。前に置くときは [ロードバランサー・CloudFront を前に置くときの国での絞り込み](../notes/ec2-operations/access-restriction-alb-cloudfront.md) |

## 流し方

どのステップも、踏み台サーバーで次の形で流す（`<ステップ>` はファイルの名前）。

```bash
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/<ステップ>.sh >> ./output/result.txt
```

- 踏み台サーバーのファイルの中身を、対象のサーバーの `bash` に標準入力で送って実行する（対象のサーバーにファイルを置く必要はない）。エラーの出力も残すなら `>> ./output/result.txt 2>&1`
- スクリプトの中で標準入力を読むコマンドを使うと、残りのスクリプトを読んでしまい、そこから後が実行されない。そのようなコマンド（`yum`）には `< /dev/null` を付けている
- どのファイルも `set -euo pipefail` で、途中のコマンドが失敗したらそこで止まる

## このドキュメントの前提

| 項目 | 内容 |
|---|---|
| 流し方 | 上の「流し方」。複数台へは、踏み台サーバーにある今のスクリプトで |
| ファイルの置き場所（踏み台サーバー） | **`command/port_guard/` の下には、対象のサーバーに送るファイルだけを置く**（ステップ 0-2 の `00-vpc-cidr.sh`、ステップ 1〜6、一覧を新しくしたときの保存し直しの `save-ipv4.sh`・`save-ipv6.sh`、サービスの確認・停止・無効化・アンインストールの `status.sh`・`stop.sh`・`disable.sh`・`uninstall.sh`・`purge.sh`）。踏み台サーバーで実行するもの（ステップ 0-1 の `make-jp-lists.sh`、ステップ 3-1 の 1 行ずつのコマンド）は、カレントのフォルダに置く・カレントのフォルダで実行する。一覧は `port_guard_whitelists/` |
| 日本の範囲の一覧を作る場所 | **踏み台サーバー**（IPv4 と IPv6）。対象のサーバーは APNIC に取りに行かない（対象のサーバーに `curl`・`python3` は要らない） |
| 一覧の渡し方 | 一覧を、ステップ 3 のファイルの中に `ipset` に読ませる行（`add <集合> <範囲>`）として並べて送る。そのファイルは、踏み台サーバーで一覧から 1 行のコマンドで作る |
| 実行する人 | `centos`。`root` の権限が要るコマンドは `sudo -n` |
| 絞るポート | 80・443 番。22 番は絞らない |
| IPv6 | 対象のサーバーに IPv6 のアドレスがあり、セキュリティグループで IPv6 の 80・443 番を通しているときだけ要る。**IPv6 の分は、どのステップも別のファイル**（名前が `-ipv6.sh` で終わるもの）にしているので、IPv6 を絞らないなら流さない |

### IPv4 と IPv6 は、ファイルも ipset の集合も分ける

| 種類 | 踏み台サーバーの一覧 | ipset の集合の名前（型） | 再起動のために保存するファイル（対象のサーバー） |
|---|---|---|---|
| 日本の範囲（IPv4） | `port_guard_whitelists/jp-ipv4.txt` | `port_guard_jp`（`hash:net family inet`） | `/etc/port-guard/ipset-ipv4.save` |
| 許可する IP アドレス（IPv4） | `port_guard_whitelists/allow-ipv4.txt` | `port_guard_allow`（`hash:net family inet`） | `/etc/port-guard/ipset-ipv4.save` |
| 日本の範囲（IPv6） | `port_guard_whitelists/jp-ipv6.txt` | `port_guard_jp6`（`hash:net family inet6`） | `/etc/port-guard/ipset-ipv6.save` |
| 許可する IP アドレス（IPv6） | `port_guard_whitelists/allow-ipv6.txt` | `port_guard_allow6`（`hash:net family inet6`） | `/etc/port-guard/ipset-ipv6.save` |

2026-11-02 の版で作った一覧のサンプルは [`samples/apnic-jp-20261102/`](./samples/apnic-jp-20261102/README.md) に置いている（取り直した一覧と比べて、大きく変わっていないかを見るのに使える）。

### ステップの一覧

**どのステップが要るか**

| 入れ方 | 流すステップ | 再起動すると |
|---|---|---|
| **設定だけ（永続化しない）** | 0 → 1 → 2 → 3 → 4 | 集合もルールも消えて、80・443 番の絞り込みが外れる（元の状態に戻る）。もう一度効かせるには、ステップ 2 から流し直す（下の「注意」） |
| **永続化する** | 0 → 1 → 2 → 3 → 4 → 5 → 6 | 起動のたびに、サービスが集合とルールを入れ直す（絞り込みが効いたまま） |

- 設定だけは、試しに入れて様子を見るとき向け。問題があっても、再起動すれば元に戻る
- 永続化するときも、ステップ 4 まで流して結果（日本からつながる・海外から止まる）を確かめてから、ステップ 5・6 を流す
- 設定だけで入れた台を後から永続化するなら、ステップ 5・6 を足して流すだけでよい（再起動していなければ、ステップ 0〜4 は流し直さなくてよい）
- IPv6 も絞る台は、ステップ 2〜5 の `-ipv6.sh` も流す（ステップ 0・1・6 は IPv4・IPv6 で共通）

| ステップ | どこで | ファイル | すること | このステップの後の状態 |
|---|---|---|---|---|
| 0 | 踏み台サーバー（VPC の範囲を調べるときだけ対象のサーバー） | `make-jp-lists.sh`・`command/port_guard/00-vpc-cidr.sh` | 踏み台サーバーが、APNIC の一覧から日本の IPv4・IPv6 の範囲の一覧を作る。許可する IP アドレスの一覧（VPC の範囲を含む）を作業者が書く | 対象のサーバーは何も変わらない |
| 1 | 対象のサーバー | `command/port_guard/01-install.sh` | 対象のサーバーに ipset を入れ、邪魔になるものがないかを確かめる（iptables は最初から入っている） | 通信は今までどおり |
| 2 | 対象のサーバー | `command/port_guard/02-sets-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーに、ipset の空の集合を作る | 通信は今までどおり |
| 3 | ファイルを作るコマンドは踏み台サーバーで実行し、作られたファイルは踏み台サーバーにある今のスクリプトで各サーバーに流す | `command/port_guard/03-jp-ipv4.sh`・`03-allow-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーの ipset の集合に、一覧を入れる | 通信は今までどおり（ipset の集合はルールから参照されるまで何もしない） |
| 4 | 対象のサーバー | `command/port_guard/04-rules-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーに iptables のルールを入れる | **ここから 80・443 番の絞り込みが効く**（再起動すると消える） |
| 5 | 対象のサーバー | `command/port_guard/05-persist-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーで、ipset の集合をファイルに保存し、起動時に入れ直すコマンドの並びを置く | 再起動するとまだ消える（ステップ 6 で有効にする） |
| 6 | 対象のサーバー | `command/port_guard/06-service.sh` | 対象のサーバーに、起動時に動くサービス `port-guard.service` を置いて有効にする | **再起動の後も効く** |

各ステップの結果（`result.txt`）を見てから、次のステップを流す。

### 注意: ステップ 6 の前に対象のサーバーを再起動したら、ステップ 2 から流し直す

ステップ 6（起動時に動くサービスを有効にする）を流す前に対象のサーバーを再起動すると、**集合もルールも消えて、80・443 番の絞り込みも外れる**（集合とルールはカーネルのメモリーにしかないため）。ステップ 6 まで流してあれば、起動時にサービスが入れ直すので、流し直しは要らない。

| もの | 再起動の後 |
|---|---|
| ipset の集合（ステップ 2・3） | **消える**（カーネルのメモリーにしかない） |
| iptables・ip6tables のルール（ステップ 4） | **消える**（同じくカーネルのメモリー） |
| ipset のパッケージ（ステップ 1） | 残る（ディスクに入っている） |
| 保存したファイルと、起動時のコマンドの並び（ステップ 5） | 残る（ただし、ステップ 6 がないと起動時には使われない） |
| 踏み台サーバーの一覧（ステップ 0）と、ステップ 3 のファイル | 残る（踏み台サーバーの上にある） |

流し直す順番（IPv6 も絞る台は、IPv6 の分も）:

1. `02-sets-ipv4.sh`（ipset の空の集合を作る）
2. `03-jp-ipv4.sh`・`03-allow-ipv4.sh`（ipset の集合に一覧を入れる。前に作ったファイルをそのまま使える。ステップ 0 と、ステップ 3 のファイルの作り直しは、一覧を新しくしたいときだけ）
3. `04-rules-ipv4.sh`（ルールを入れる。ここで絞り込みが効く）
4. 再起動の後も残すなら、`05-persist-ipv4.sh` と `06-service.sh`

ステップ 2 と 3 は飛ばせない。ステップ 4 のルールは集合を名前で参照するので、集合がないとルールを入れられずに失敗する。また、ステップ 4 は日本の集合が 1,000 件（IPv6 は 200 件）未満だと止まる。

## ステップ 0: 踏み台サーバーで、日本の範囲の一覧と、許可する IP アドレスの一覧を作る

### 0-1. 踏み台サーバーが、日本の IP アドレスの範囲の一覧を作る

踏み台サーバーが APNIC の一覧を取り、日本（`JP`）の行だけを取り出して、1 行 1 件の CIDR の一覧にする。`awk`（行ごとに文字列を加工するコマンド。どの Linux にも入っている）だけで行うので、踏み台サーバーに Python は要らない。

- **IPv6** は「先頭のアドレス」と「CIDR の長さ」で書かれているので、`/` でつなぐだけで CIDR になる（例: `2001:200::` と `35` → `2001:200::/35`）
- **IPv4** は「先頭のアドレス」と「個数」で書かれている。個数は 2 のべき乗（256、512、1024…）とは限らないので、CIDR で書ける区切りに分ける。例: 先頭 `10.0.0.0`・個数 768 → `10.0.0.0/23`（512 個）と `10.0.2.0/24`（256 個）。下の `while` の部分が、この分け方をしている（先頭から、区切りのよい、なるべく大きな塊を切り出していく）

`make-jp-lists.sh`（踏み台サーバーで `bash make-jp-lists.sh` と実行する）:

```bash
#!/bin/bash
# 踏み台サーバーで実行する。APNIC の割り当ての統計から、日本の IPv4・IPv6 の範囲の一覧を port_guard_whitelists/ に作る
set -euo pipefail
mkdir -p port_guard_whitelists
curl -fsS --max-time 120 -o port_guard_whitelists/delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest

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
}' port_guard_whitelists/delegated-apnic-latest > port_guard_whitelists/jp-ipv4.txt

# IPv6: 先頭のアドレスと長さを、そのまま CIDR にする
awk -F'|' '$2 == "JP" && $3 == "ipv6" && ($7 == "allocated" || $7 == "assigned") { print $4 "/" $5 }' \
  port_guard_whitelists/delegated-apnic-latest > port_guard_whitelists/jp-ipv6.txt

echo "IPv4: $(wc -l < port_guard_whitelists/jp-ipv4.txt) 件、IPv6: $(wc -l < port_guard_whitelists/jp-ipv6.txt) 件"
```

| 行 | 意味 |
|---|---|
| `curl -fsS --max-time 120 -o <ファイル> <URL>` | APNIC の一覧を取ってファイルに保存する。`-f` は、取れなかったとき（サーバーのエラー）に失敗を返す。`--max-time 120` は 120 秒で諦める |
| `awk -F'|' '...'` | 各行を `|` で区切り、`$2`（2 番目）・`$3`・`$4`… で項目を参照する。条件に合う行だけを処理する |
| `ip2n`・`n2ip` | IPv4 のアドレスと数とを行き来する計算（`1.0.16.0` ↔ 16,781,312）。範囲を数として扱って区切るため |
| `wc -l` | 行数（件数）を数える |

| 点 | 内容 |
|---|---|
| 件数の目安 | 2026-11-02 の時点で IPv4 4,738 件、IPv6 766 件。ステップ 4 は、日本の集合がこの約 5 分の 1（IPv4 1,000 件・IPv6 200 件）より少なければ止まる（一覧の取得や加工に失敗して空に近い一覧を入れると、日本からも受け付けなくなるため）。件数が大きく変わったら、この基準を見直す |
| 取得に失敗したとき | `curl` が失敗すれば、そこで止まる（`set -e`）。前回の `port_guard_whitelists/jp-*.txt` はそのまま残る |

### 0-2. 作業者が、許可する IP アドレスの一覧を書く

踏み台サーバーに `port_guard_whitelists/allow-ipv4.txt`（と、IPv6 も絞るなら `port_guard_whitelists/allow-ipv6.txt`）を手で置く。1 行 1 件、CIDR でもよい、`#` から後はコメント、空の行は無視される。ここに書いた送り元は、日本の範囲に入っていなくても 80・443 番を受け付ける。

書くもの:

| 送り元 | 書く理由 |
|---|---|
| **対象のサーバーが入っている VPC の範囲**（必ず書く） | VPC の中から来る通信の送り元はプライベートのアドレスで、日本の範囲の一覧に入らない。書かないと、同じ VPC のほかのサーバーからの呼び出し、VPC の中からの監視、踏み台サーバーからプライベートのアドレスで行う確認（ステップ 4 の `curl`）が、すべて捨てられる |
| VPC とつながったほかのネットワーク（あれば） | VPC のピアリング（VPC 同士の接続）、VPN、Direct Connect（専用線）でつながった先から 80・443 番へ来る通信があれば、その範囲 |
| 日本の外から受ける必要がある相手（あれば） | 海外の拠点、外部のサービス（決済などの通知）、海外からの外形監視など |
| 同じリージョンのほかの EC2 から、公開のアドレスで来る通信（あれば） | AWS の公開のアドレスは、多くが米国の組織（ARIN）の登録で、東京リージョンのものでも日本の範囲の一覧にほとんど入らない。公開のアドレスで呼んでくる EC2 があれば、その Elastic IP を書く |

`port_guard_whitelists/allow-ipv4.txt` の例:

```
# 対象のサーバーの VPC（command/port_guard/00-vpc-cidr.sh の結果）
10.0.0.0/16
# 海外の拠点
203.0.113.10
```

VPC の範囲は、対象のサーバーのどれか 1 台に次のファイルを流すと分かる（同じ VPC の台なら、どの台でも同じ結果）。対象のサーバーが、自分の情報を AWS から聞く仕組み（インスタンスメタデータ。サーバーの中から `169.254.169.254` に問い合わせる。AWS の操作の権限は要らない）を使う。**読み取るだけで、何も変えない**。

`command/port_guard/00-vpc-cidr.sh`:

```bash
#!/bin/bash
# 対象のサーバーが入っている VPC の範囲（CIDR）を表示する（読み取りだけ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 00-vpc-cidr"

IMDS=http://169.254.169.254   # インスタンスメタデータサービス（IMDS）の入り口。AWS が決めたアドレスで、公式の名前（DNS 名）はない
TOKEN=$(curl -fsS -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' $IMDS/latest/api/token)
MAC=$(curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $TOKEN" $IMDS/latest/meta-data/mac)
echo "IPv4 の VPC の範囲:"
curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv4-cidr-blocks"; echo
echo "IPv6 の VPC の範囲:"
curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv6-cidr-blocks" || echo "（なし）"; echo
```

| 行 | 意味 |
|---|---|
| `IMDS=http://169.254.169.254` | インスタンスメタデータサービスの入り口を、名前（`IMDS`）を付けた変数にしておく。以降の問い合わせは `$IMDS/...` と書く。AWS はこの仕組みに DNS の名前を用意しておらず、AWS のドキュメントもアドレスで案内している（下の「なぜ…から調べるか」） |
| `TOKEN=$(curl ... -X PUT ... /latest/api/token)` | インスタンスメタデータに問い合わせるための、60 秒だけ使える合言葉（トークン）をもらう（インスタンスメタデータの新しい形（IMDSv2）の決まり。古い形しか許していない台でも、この形で問い合わせられる） |
| `MAC=$(curl ... /meta-data/mac)` | このサーバーのネットワークの口の識別子（MAC アドレス）を聞く。VPC の情報は、口ごとに聞く形になっているため |
| `curl ... /vpc-ipv4-cidr-blocks` | その口が入っている VPC の IPv4 の範囲を聞く。VPC に範囲を足してある場合は、複数行で出る。`; echo` は、結果の末尾に改行がないので足すだけ |
| `curl ... /vpc-ipv6-cidr-blocks || echo "（なし）"` | VPC の IPv6 の範囲を聞く。VPC が IPv6 の範囲を持っていなければ、問い合わせが失敗するので「（なし）」と出す |

結果の例:

```
== web01 2026-11-04 10:00:00 00-vpc-cidr
IPv4 の VPC の範囲:
10.0.0.0/16
IPv6 の VPC の範囲:
（なし）
```

出た IPv4 の範囲を `port_guard_whitelists/allow-ipv4.txt` に、IPv6 の範囲が出たら（IPv6 も絞る台では）`port_guard_whitelists/allow-ipv6.txt` に書く。AWS CLI が使える場所からなら、`aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock]' --output text` でも分かる。

**なぜインスタンスメタデータ（`169.254.169.254`）から調べるか（経緯）**

2026-11-04 に、「VPC の中から来る通信の送り元はプライベートのアドレスで、日本の範囲の一覧に入らないので、VPC の範囲を許可の一覧に入れる必要がある」と分かった。そのとき、VPC の範囲をどこから調べるかを、次の 2 つから選んだ。

| 調べ方 | 要るもの | 選んだか |
|---|---|---|
| 対象のサーバーの中から、インスタンスメタデータ（`169.254.169.254`）に問い合わせる | `curl`（Amazon Linux 2 に最初から入っている）だけ。AWS の操作の権限も、AWS CLI も要らない | **選んだ** |
| AWS CLI で `aws ec2 describe-vpcs` を呼ぶ | AWS CLI と、EC2 の情報を読む権限（`ec2:DescribeVpcs`）。踏み台サーバーにあるとは限らない | 予備（AWS CLI が使える場所なら、これでもよい） |

選んだ理由:

- **ほかのステップと同じ形で流せる**。踏み台サーバーから SSH で `bash` に流すだけで、踏み台サーバーに AWS の権限を持たせなくてよい
- **取り違えない**。インスタンスメタデータは「問い合わせてきたインスタンス自身の情報」を返すので、その台が実際に入っている VPC の範囲が出る（VPC が複数あっても、どれがその台の VPC かを人が見分けなくてよい）
- **読み取りだけ**。何も変えない。問い合わせは料金もかからない

`169.254.169.254` は、AWS が EC2 のインスタンスに用意している決まったアドレス（インスタンスメタデータサービス、IMDS）。リンクローカル（そのインスタンスの中からだけ届くアドレス）で、インターネットや VPC のどこかにあるサーバーではない。インスタンスが載っている AWS の基盤が、そのインスタンスからの問い合わせにだけ答える。外（踏み台サーバーなど）から、別のインスタンスの情報を聞くことはできない。

**名前（DNS 名）ではなくアドレスで書く理由**: AWS のドキュメントは、インスタンスメタデータサービスをアドレス（IPv4 は `169.254.169.254`、IPv6 は `fd00:ec2::254`）でだけ案内していて、公式の名前はない（2026-11-04 に確かめた）。名前を使う形は DNS の設定に左右されるので使わない。その代わり、スクリプトの中では `IMDS` という名前の変数に入れて、何のアドレスかが分かるようにしている。

このやり方は、AWS が公開している仕組みに沿っている（2026-11-04 に、下の AWS のドキュメントと照らし合わせた）。

| 使っているもの | AWS のドキュメントでの説明 |
|---|---|
| `http://169.254.169.254/latest/meta-data/` | インスタンスメタデータの入り口。リンクローカルのアドレスで、インスタンスの中からだけ有効 |
| `PUT /latest/api/token`（`X-aws-ec2-metadata-token-ttl-seconds`）でトークンを取り、`X-aws-ec2-metadata-token` に付けて問い合わせる | IMDSv2（新しい形）の問い合わせ方。古い形（IMDSv1）しか許していない台でも、この形は使える。IMDSv2 が必須の台では、古い形は使えない |
| `meta-data/mac` | インスタンスの MAC アドレス（ネットワークの口が複数あるときは、最初の口 `eth0`） |
| `meta-data/network/interfaces/macs/<MAC>/vpc-ipv4-cidr-blocks` | その口が入っている VPC の IPv4 の範囲（複数あれば複数行） |
| `meta-data/network/interfaces/macs/<MAC>/vpc-ipv6-cidr-blocks` | その VPC の IPv6 の範囲（ない場合は `404 - Not Found` になるので、`curl -f` が失敗を返す） |
| `curl -f` | AWS のドキュメントにも、`-f` を付けると HTTP のエラーのときに失敗を返し、スクリプトで止められると書かれている |

AWS のドキュメント:

- [Use instance metadata to manage your EC2 instance（インスタンスメタデータとは。項目の一覧（Instance metadata categories）に `mac`・`vpc-ipv4-cidr-blocks`・`vpc-ipv6-cidr-blocks` がある）](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html)
- [Access instance metadata for an EC2 instance（`169.254.169.254` への問い合わせ方、IMDSv2 のトークン、エラーのときの応答）](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html)
- [Use the Instance Metadata Service to access instance metadata（IMDSv1 と IMDSv2 の違い）](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [Link-local addresses（リンクローカルのアドレス）](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-instance-addressing.html#link-local-addresses)

**VPC の範囲を丸ごと許可するのは、VPC の中を信頼する前提**。VPC の中の特定のサーバーからだけ受けたいなら、VPC の範囲の代わりに、そのサーバーのプライベートのアドレスを 1 件ずつ書く（ただし、踏み台サーバーからの確認もそのアドレスを書かないと止まる）。

## ステップ 1: 対象のサーバーに ipset を入れ、邪魔になるものがないかを確かめる（`command/port_guard/01-install.sh`）

iptables は Amazon Linux 2 に最初から入っている。ipset は入っていないことがあるので入れる。あわせて、このあと入れるルールを起動時に上書きしてしまうものが動いていないかを確かめる。

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

| 行 | 意味 |
|---|---|
| `yum install -y -q ipset < /dev/null` | パッケージ（ソフトウェアの配布の単位）`ipset` を入れる。`-y` は確認の問い合わせに自動で「はい」、`-q` は表示を減らす。`< /dev/null` は標準入力を読ませないため（上の「流し方」）。すでに入っていれば何もしない |
| `rpm -q iptables ipset` | パッケージが入っているかと、その版を表示する |
| `iptables -V` | iptables の版を表示する |
| `ipset version` | ipset の版を表示する |
| `command -v ipset iptables ip6tables` | 各コマンドのファイルの場所を表示する |
| `systemctl is-enabled ...`・`is-active ...` | `iptables`・`ip6tables`・`ipset` という名前のサービスが、起動時に動く設定か（enabled）、今動いているか（active）を表示する。`paste -sd' ' -` は、複数行の結果を 1 行にまとめるだけ |

| 結果の見方 | 内容 |
|---|---|
| `iptables -V` | `v1.6` 以上であること（ステップ 4 以降の `-w 10`（秒数を付けたロック待ち）が使える。Amazon Linux 2 は 1.8 系の見込み）。`(legacy)` と付くのが Amazon Linux 2 の普通の形 |
| `ipset version` | 版が出れば入っている |
| `command -v` | `/usr/sbin/ipset`・`/usr/sbin/iptables`・`/usr/sbin/ip6tables` であること。ステップ 5 のファイルにはこの場所を書いている（違えば、ステップ 5 の `ExecStart=` の場所を直す） |
| `iptables`・`ip6tables`・`ipset` のサービス | **どれも `enabled`・`active` でないこと**（`disabled`・`inactive`、またはサービスがないと表示される）。これらは `iptables-services` などのパッケージが入れるサービスで、起動時に、保存されたルールの一式でカーネルのルールを**丸ごと置き換える**。動いていると、この手順のルールが起動時に消されたり、この手順のサービスとぶつかったりする（`iptables` のサービスの既定のルールは、SSH 以外の受信を拒否する）。見つかったら、その台は先へ進めずに理由を調べる |

ipset に要るカーネルの部品（モジュール `ip_set`・`xt_set`）は、集合を作ったときや、ルールから参照したときに自動で読み込まれる。再起動は要らない。

## ステップ 2: 対象のサーバーに、ipset の空の集合を作る（`command/port_guard/02-sets-ipv4.sh`・`02-sets-ipv6.sh`）

ipset の集合（ipset で作る、IP アドレスの範囲の集まり。カーネルの中に名前を付けて置く）を、日本の範囲用と許可する IP アドレス用に、中身が空の状態で作る。**通信には何も影響しない**。

`command/port_guard/02-sets-ipv4.sh`:

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

`command/port_guard/02-sets-ipv6.sh`（IPv6 も絞るときだけ）:

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
| `ipset create <名前> <型> ...` | 集合を作る |
| `-exist` | 同じ名前の集合がすでにあっても失敗にしない（もう一度流してもよい） |
| `hash:net` | CIDR の範囲を入れる型（範囲の長さはばらばらでよい） |
| `family inet` / `family inet6` | IPv4 用 / IPv6 用 |
| `maxelem 65536` | 入れられる件数の上限（日本の範囲は数千件なので足りる） |
| `ipset list -t <名前>` | 集合の情報（中身の一覧は除く）を表示する |

結果の例（`ipset list -t port_guard_jp`。数値は環境で変わる）:

```
Name: port_guard_jp
Type: hash:net
Revision: 6
Header: family inet hashsize 1024 maxelem 65536
Size in memory: 448
References: 0
Number of entries: 0
```

`Number of entries`（入っている件数）が 0、`References`（この集合を参照しているルールの数）が 0 であること。

## ステップ 3: 踏み台サーバーで ipset の集合に入れるファイルを作り、各サーバーで流して ipset の集合に一覧を入れる（`command/port_guard/03-*.sh`）

一覧は件数が多い（IPv4 は約 4,700 件）ので、手で書くのではなく、踏み台サーバーで一覧からファイルを作る。**作られるファイルの中身は、ipset の集合を空にするコマンドと、ipset に読ませる `add <集合> <範囲>` の行を並べたものだけ**。

このステップは、実行する場所が 2 つに分かれる。

| 順 | どこで実行するか | 何を実行するか | 結果 |
|---|---|---|---|
| 3-1 | **踏み台サーバー**（カレントのフォルダ。対象のサーバーには送らない） | 下の 3-1 の 1 行ずつのコマンド | 踏み台サーバーに `command/port_guard/03-jp-ipv4.sh`・`03-allow-ipv4.sh`（IPv6 も絞るなら `03-jp-ipv6.sh`・`03-allow-ipv6.sh`）が作られる |
| 3-3 | **各サーバー**（踏み台サーバーにある今のスクリプトで、複数台に当て込む） | 3-1 で作られた `command/port_guard/03-*.sh` | 各サーバーの ipset の集合に、一覧が入る |

### 3-1. 踏み台サーバーで、ファイルを作る

**踏み台サーバーのカレントのフォルダで**、次の 1 行ずつを実行する（一覧の `#` から後のコメントと、空の行は除く）。これらは対象のサーバーには送らない。実行すると、対象のサーバーに送るファイルが `command/port_guard/` に作られる。

```bash
mkdir -p command/port_guard
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv4.txt | awk 'NF { print "add port_guard_jp " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp'; } > command/port_guard/03-jp-ipv4.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv4.txt | awk 'NF { print "add port_guard_allow " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow'; } > command/port_guard/03-allow-ipv4.sh

# IPv6 も絞るときだけ
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv6.txt | awk 'NF { print "add port_guard_jp6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp6'; } > command/port_guard/03-jp-ipv6.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv6.txt | awk 'NF { print "add port_guard_allow6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow6'; } > command/port_guard/03-allow-ipv6.sh
```

1 行の読み方（1 行目の例）:

| 部分 | 意味 |
|---|---|
| `{ ...; ...; } > command/port_guard/03-jp-ipv4.sh` | `{ }` の中の各コマンドの出力を、順に 1 つのファイルに書く |
| `echo '...'` | その文字列を 1 行として書く（ファイルの先頭の `#!/bin/bash` などと、末尾の確認の行） |
| `sed 's/#.*//' port_guard_whitelists/jp-ipv4.txt` | 一覧の各行の `#` から後（コメント）を消す |
| `awk 'NF { print "add port_guard_jp " $1 }'` | 空でない行（`NF` は項目の数。空の行は 0）ごとに、`add port_guard_jp <範囲>` の行を書く |

### 3-2. 作られるファイルの中身

`command/port_guard/03-jp-ipv4.sh`（途中の行は省略。2026-11-02 の一覧で 4,744 行、約 160 KB）:

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

`command/port_guard/03-allow-ipv4.sh`（許可する IP アドレスが 1 件のとき）:

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
| `ipset restore -exist <<'EOF'` 〜 `EOF` | 間の `add` の行をまとめて読み込む（1 件ずつ `ipset add` を 4,700 回呼ぶより、ずっと速い）。`-exist` は、同じ範囲が重なっても失敗にしない |
| `ipset list -t <集合>` | 結果の確認。`Number of entries` が一覧の件数と同じになっていること |

### 3-3. 各サーバーで流す

3-1 で作られた `command/port_guard/03-jp-ipv4.sh` と `command/port_guard/03-allow-ipv4.sh`（IPv6 も絞るなら `03-jp-ipv6.sh`・`03-allow-ipv6.sh` も）を、**踏み台サーバーにある今のスクリプトで、各サーバー上で実行する**（ほかのステップと同じ形。1 台なら `ssh ... 'bash' < ./command/port_guard/03-jp-ipv4.sh >> ./output/result.txt`）。

| 点 | 内容 |
|---|---|
| まだ効かない | ipset の集合は、ステップ 4 の iptables のルールから参照されるまで何もしない。このステップの後も、80・443 番は今までどおり |
| 入っているかを 1 件ずつ確かめる | 対象のサーバーで `sudo ipset test port_guard_jp 1.0.16.1`。入っていれば `is in set` と表示される（終了コード 0） |
| 一覧を作り直したら | ステップ 0 の後に、3-1 の 1 行ずつでファイルを作り直す |
| 絞り込みが効いた後に流し直すとき | `flush` してから入れ直すまでの短い間（1 秒もかからない）、集合が空になり、日本からの接続も捨てられる。永続化している台では、入れ直した後に `command/port_guard/save-ipv4.sh`（と `save-ipv6.sh`）も流して、起動時に読み込むファイルを保存し直す（後の「日本の範囲の一覧を新しくするとき」の 4） |

## ステップ 4: 対象のサーバーに iptables のルールを入れる。ここから絞り込みが効く（`command/port_guard/04-rules-ipv4.sh`・`04-rules-ipv6.sh`）

**ここから 80・443 番の絞り込みが効く**。80・443 番は、日本の範囲と許可する IP アドレスからだけ受け付ける。22 番は絞らないので、踏み台サーバーからの SSH は今までどおり入れる。

**この時点では、再起動するとルールも集合も消える**（ステップ 5・6 で残す。その前に再起動したら、上の「注意: ステップ 6 の前に対象のサーバーを再起動したら、ステップ 2 から流し直す」のとおり流し直す）。

`command/port_guard/04-rules-ipv4.sh`:

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

`command/port_guard/04-rules-ipv6.sh`（IPv6 も絞るときだけ。`iptables` が `ip6tables` に、集合が IPv6 のものに、件数の基準が 200 件に変わるだけ）:

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

ルールを入れる前の 2 つ:

| 行 | 意味 |
|---|---|
| `[ "$(... Number of entries ...)" -ge 1000 ] || { ...; exit 1; }` | 日本の集合の件数（`ipset list -t` の `Number of entries` の数）を取り出し、1,000 以上でなければ、メッセージを出して止める。ステップ 3 を流し忘れた・失敗したまま進むと、日本からの接続も全部捨ててしまうため |
| `install -d -m 700 /var/lib/port-guard` | 控えを置くフォルダを作る（`root` だけが読める。すでにあれば何もしない） |
| `iptables-save > .../iptables-before-<日時>.txt` | 今のルールの一式を、日時付きのファイルに書き出して控える（何か問題があったときに、入れる前の状態を見る手がかり） |

ルールの 1 行ずつ:

| 行 | 意味 |
|---|---|
| `-w 10` | ほかのものが iptables を操作している（ロックを持っている）間は、終わるまで最大 10 秒待つ。1 回のコマンドがロックを持つのは一瞬なので、普通はすぐ空く。10 秒たっても空かなければ失敗して、`set -e` でそこで止まる（秒数なしの `-w` は空くまで待ち続けるので、止まったまま気付かないことがある）。秒数を付けた形は iptables 1.6 以上（ステップ 1 の `iptables -V`） |
| `-N PORT_GUARD` | 自前のチェーン `PORT_GUARD` を作る。**すでにあれば失敗して、そこで止まる**（二重に入れないため。入れ直すときは、下の「うまくいかなかったときに外す」の後に流す） |
| `-A PORT_GUARD -i lo -j ACCEPT` | `-A` はチェーンの末尾に足す。`-i lo` は「同じマシンの中から来た通信」（`lo` はマシンの中だけの仮の通信の口）。対象のサーバーの中から自分の 80・443 番を呼ぶ通信（動作確認の `curl localhost` など）は通す |
| `-A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT` | `-m set --match-set <集合> src` は「送り元（`src`）の IP アドレスが、その集合に入っている」。許可する IP アドレスなら通す |
| `-A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT` | 送り元が日本の範囲なら通す |
| `-A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "` | ここまで来た（通さなかった）通信を記録する。`-m limit --limit 10/min` は「1 分に 10 件まで」（大量に来ても記録があふれないように）。記録には `port-guard drop: ` が頭に付き、`sudo journalctl -k | grep port-guard` か `/var/log/messages` で見られる。`LOG` は記録するだけで、次の行へ進む |
| `-A PORT_GUARD -j DROP` | 残りを捨てる。相手には何も返さないので、相手は時間切れまで待つ |
| `-I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD` | `-I INPUT 1` は、カーネルの `INPUT` チェーンの 1 番目（いちばん上）にルールを差し込む（すでにあるルールより先に照合させるため）。`-p tcp -m multiport --dports 80,443` は「TCP で、あて先のポートが 80 か 443」。その通信を `PORT_GUARD` へ飛ばす。**この 1 行が入った時点で絞り込みが効く**（だから最後に入れる） |
| `-S <チェーン>` | チェーンのルールを、入れたときのコマンドの形で表示する。`grep -- '-j PORT_GUARD'` は、そのうち `PORT_GUARD` へ飛ばす行だけを表示する |

結果のファイルに出る確認の部分（おおむね次の形）:

```
-N PORT_GUARD
-A PORT_GUARD -i lo -j ACCEPT
-A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
-A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
-A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
-A PORT_GUARD -j DROP
-A INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
```

| 確かめること | どこで | 内容 |
|---|---|---|
| ルールが入ったか | 結果のファイル | 上の 7 行が表示されること（`PORT_GUARD` チェーンを作った印の 1 行と、その中の 5 つのルール、`INPUT` チェーンの 1 つのルール。`iptables -S` は、カーネルの中のルールを 1 つ 1 行で表示する） |
| VPC の中からつながるか | 踏み台サーバー（同じ VPC にあれば） | `curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://<server のプライベートのアドレス>/` と `curl -sk -o /dev/null -m 5 -w '%{http_code}\n' https://<server のプライベートのアドレス>/`。`200` や `301` など、`000` 以外の数が出れば応答がある（`-m 5` は 5 秒で諦める。`000` は応答がなかったという意味）。`000` なら、ステップ 0-2 の VPC の範囲が抜けている |
| 日本からつながるか | 日本にある、VPC の外のマシン（作業者の PC など） | 同じ `curl` を、対象のサーバーの公開のアドレスあてに流す。`000` 以外が出ること |
| 海外から止まるか | 海外の確認用のマシン | 同じ `curl` が `000`（5 秒で時間切れ）になること |

### うまくいかなかったときに外す

次のコマンドで、80・443 番の絞り込みを外せる（カーネルの `INPUT` チェーンから、`PORT_GUARD` へ飛ばすルールを 1 つ削除する。ファイルは編集しない。集合と `PORT_GUARD` チェーンは残るが、どこからも飛んでこないので何もしない）。IPv6 は `iptables` を `ip6tables` にして同じ。

```bash
#!/bin/bash
# 遮断を外す（カーネルの INPUT チェーンから、PORT_GUARD へ飛ばすルールを 1 つ削除する）
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
```

`-D` は、指定したのと同じ内容のルールを消す。チェーンも消して、ステップ 4 を流し直せる状態に戻すなら、続けて `sudo -n iptables -w 10 -F PORT_GUARD`（チェーンの中身を空にする）と `sudo -n iptables -w 10 -X PORT_GUARD`（空のチェーンを消す）。

ステップ 6 まで流してある台では、外しても、次の再起動でサービスがまた入れる。起動時にも入れないようにするなら、あわせて `sudo -n systemctl disable port-guard`。

## ステップ 5: 対象のサーバーで ipset の集合を保存し、起動時に ipset の集合と iptables のルールを入れ直すコマンドの並びを置く（`command/port_guard/05-persist-ipv4.sh`・`05-persist-ipv6.sh`）

集合とルールは、カーネルのメモリーにしかないので、再起動すると消える。そこで、

1. 今の ipset の集合の中身を、ファイルに保存する（`ipset save`）
2. 起動時に「保存した ipset の集合を読み込み、ステップ 4 と同じルールを入れる」コマンドの並びを、systemd の**追加の設定（ドロップイン）のファイル**に書いておく
3. ステップ 6 で、それを動かすサービス `port-guard.service` を置いて有効にする

IPv4 の分と IPv6 の分は、**別々の追加の設定のファイル**に置く。サービスは IPv4・IPv6 で 1 つ。

| ファイル（対象のサーバー） | 置くステップ | 中身 |
|---|---|---|
| `/etc/port-guard/ipset-ipv4.save` | 5（IPv4） | IPv4 の集合を `ipset save` で保存したもの |
| `/etc/systemd/system/port-guard.service.d/10-ipv4.conf` | 5（IPv4） | 起動時に IPv4 の集合を読み込み、ステップ 4 と同じルールを入れる `ExecStart=` の並び |
| `/etc/port-guard/ipset-ipv6.save` | 5（IPv6） | IPv6 の集合を保存したもの |
| `/etc/systemd/system/port-guard.service.d/20-ipv6.conf` | 5（IPv6） | IPv6 の分の `ExecStart=` の並び |
| `/etc/systemd/system/port-guard.service` | 6 | サービスの本体。`ExecStart=` は書かない（上の 2 つから集まる） |

systemd は、`port-guard.service` を読むときに、`port-guard.service.d/` の中の `*.conf` を**ファイルの名前の順に**読み、`ExecStart=` を本体に足していく。この仕組みで、次のようになる。

- **IPv4・IPv6 のどちらも、入れるかどうかを選べる**: 置いたファイルの分だけが動く。IPv6 を絞らない台では `05-persist-ipv6.sh` を流さない。後から外すときは、そのファイルを消して `systemctl daemon-reload` するだけ（後の「IPv4・IPv6 を後から外す・足す」）
- **IPv4 → IPv6 の順に、1 つずつ動く**: `10-` が `20-` より先に読まれ、1 つのサービスの `ExecStart=` は上から順に 1 つずつ動く。IPv4 と IPv6 が同じ時刻に iptables を操作することがないので、ロックの取り合いが起きない（IPv4 と IPv6 で 2 つのサービスに分けると、systemd が 2 つを同時に起動して、ロックを取り合い、片方が `Another app is currently holding the xtables lock` で失敗する。前の版の手順では 2 つに分けていて、Amazon Linux 2 の上で実際に起きたので、1 つにまとめた）
- ステップ 1〜5 は、IPv4・IPv6 で別のファイルのまま。1 つにまとまるのは、サービスだけ

ステップ 4 の結果を確かめてから流す。

`command/port_guard/05-persist-ipv4.sh`:

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

`command/port_guard/05-persist-ipv6.sh`（IPv6 も絞るときだけ）:

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
| `install -d -m 755 <フォルダ>` | フォルダを作る（すでにあれば何もしない） |
| `ipset save <集合> > <ファイル>` | 集合を作る行（`create ...`）と、中身の行（`add ...`）を、`ipset restore` で読める形でファイルに書き出す。2 つ目の集合は `>>`（書き足す）で同じファイルに続ける |
| `[Service]` | ファイルの中で、ここから後がサービスの動かし方の設定であることを示す見出し |
| `ExecStart=/usr/sbin/ipset restore -exist -file <ファイル>` | 起動時に、保存した集合を読み込む（集合がなければ作り、中身を入れる）。`-exist` は、集合や中身がすでにあっても失敗にしない |
| `ExecStart=-...` の `-` | その行が失敗しても、次の行へ進む（systemd の書き方）。`-N` は「チェーンがすでにある」とき、`-D` は「`INPUT` チェーンに、`PORT_GUARD` へ飛ばすルールがまだない」ときに失敗するが、どちらも失敗してかまわないので `-` を付けている |
| `-F PORT_GUARD` | チェーンの中身を空にしてから、5 つのルールを入れ直す（何度流しても二重に入らない） |
| `-D INPUT ...` の後に `-I INPUT 1 ...` | `INPUT` チェーンから、`PORT_GUARD` へ飛ばすルールを削除してから、差し込み直す（何度流しても二重に入らない） |
| `-w 10` | ロックが空くまで最大 10 秒待つ。起動時に iptables を操作するほかのもの（Docker など）とも、取り合いで失敗しない。10 秒で空かなければ、その行で止まってサービスは `failed`（失敗）になる（`journalctl -b -u port-guard` で分かる） |
| `systemctl daemon-reload` | systemd に、置いたファイルを読み直させる |
| 確認の `head -3` | 保存したファイルの先頭 3 行（`create port_guard_jp hash:net family inet ...` と `add ...`）を表示する |
| 確認の `grep -c '^add port_guard_jp '` | 保存したファイルの中の、日本の範囲の件数。ステップ 3 の件数と同じであること |
| 確認の `grep -c '^ExecStart='` | 置いたファイルの `ExecStart=` の行数。10 であること |

`-`・`-F`・`-D` によって、**このコマンドの並びは何度流しても同じ状態になる**（起動時に何かが先にチェーンを作っていても、動いている OS の上でサービスを `start`・`restart` しても、失敗せず、二重にもならない）。ただし、動いている OS の上で流し直すと、`-F` から `DROP` を入れ直すまでの一瞬（1 秒もかからない）、80・443 番が素通りになる。起動時は、ネットワークがつながる前に流れるので関係ない。

## ステップ 6: 対象のサーバーに、起動時に動くサービスを置いて有効にする（`command/port_guard/06-service.sh`）

サービスの本体 `port-guard.service` を置き、次の起動から自動で動くようにする。ステップ 5 を（IPv4 だけ、または IPv4 と IPv6）流した後に流す。

`command/port_guard/06-service.sh`:

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

| 行 | 意味 |
|---|---|
| `[Unit]` の `Description=` | サービスの説明（`systemctl status` などで表示される） |
| `Before=network-pre.target`・`Wants=network-pre.target` | ネットワークをつなぐ前に動かす。起動の途中に、絞り込みが入っていない状態で 80・443 番を受け付ける時間ができない |
| `[Service]` の `Type=oneshot` | `ExecStart=` を上から順に 1 つずつ実行して終わる（ずっと動き続けるサービスではない）。どれかが失敗すると（`-` の付いた行を除く）、そこで止まり、サービスは `failed` になる。IPv4 の行が先なので、IPv6 の行で失敗しても、IPv4 の絞り込みは入っている |
| `RemainAfterExit=yes` | 実行が終わっても「動いている（`active`）」と表示する。入れたことが `systemctl is-active port-guard` で分かる |
| `[Install]` の `WantedBy=multi-user.target` | `enable` したときに、普通の起動の流れに組み込む |
| `systemctl enable port-guard` | 次の起動から自動で動くようにする |
| 確認の `systemctl cat port-guard` | 本体と追加の設定を、systemd が読んだとおりにまとめて表示する。`ExecStart=` の行数が、IPv4 だけなら 10、IPv4 と IPv6 なら 20 であること |
| 確認の `systemctl is-enabled port-guard` | `enabled` であること |

| 点 | 内容 |
|---|---|
| `enable` だけで、`start` はしない | ルールはステップ 4 ですでに入っているので、今 `start` する必要はない（`start` しても失敗はしないが、ステップ 5 の最後に書いた一瞬の素通りがある） |
| 本体に `ExecStart=` がない | ステップ 5 の追加の設定が 1 つもないと、systemd は「`ExecStart=` がない」としてこのサービスを読み込まない。ステップ 5 を先に流す |
| 再起動の後に確かめる | 保守の時間帯に対象のサーバーを再起動して、ステップ 4 の「確認」の 2 行（IPv6 も入れたなら `ip6tables` でも）、`systemctl is-active port-guard`（`active` であること）、`journalctl -b -u port-guard`（今回の起動での、このサービスの記録。失敗した行があれば出る） |

## 日本の範囲の一覧を新しくするとき

> **この節は、踏み台サーバーから人が流す手動の手順で、S3 による一覧の管理は想定していない**。S3 に置いた一覧を各サーバーが定期に取りに行って入れ替える形は、[補足](./bastion-install-supplement.md) の「B. 日本の範囲の一覧を定期に新しくする」で方針を決めた段階で、まだ作っていない。それができたら、この節は「S3 や定期の入れ替えが使えないときの予備」になる。

APNIC の割り当ては少しずつ変わる（月に数件〜数十件）。一覧を新しくするときは、次の順に流す。IPv6 も絞っている台は、括弧の中の IPv6 の分も流す。

**1. 踏み台サーバーで、日本の範囲の一覧を作り直す**（ステップ 0-1。カレントのフォルダで）

```bash
bash make-jp-lists.sh
```

`port_guard_whitelists/jp-ipv4.txt`（と `jp-ipv6.txt`）が新しくなる。最後に出る件数が、前回と大きく変わっていないことを確かめる。

**2. 踏み台サーバーで、ipset の集合に入れるファイルを作り直す**（ステップ 3-1 のうち、日本の範囲の行。踏み台サーバーのカレントのフォルダで実行する）

```bash
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv4.txt | awk 'NF { print "add port_guard_jp " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp'; } > command/port_guard/03-jp-ipv4.sh

# IPv6 も絞っている台があるときだけ
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv6.txt | awk 'NF { print "add port_guard_jp6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp6'; } > command/port_guard/03-jp-ipv6.sh
```

`command/port_guard/03-jp-ipv4.sh`（と `03-jp-ipv6.sh`）が新しい一覧の中身で作り直される。

**3. 作り直したファイルを、踏み台サーバーにある今のスクリプトで各サーバーに流して、ipset の集合の中身を入れ替える**（ステップ 3-3）

```bash
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/03-jp-ipv4.sh >> ./output/result.txt
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/03-jp-ipv6.sh >> ./output/result.txt   # IPv6 も絞っている台だけ
```

- カーネルの中の集合 `port_guard_jp`（と `port_guard_jp6`）の中身が、新しい一覧に入れ替わる。iptables のルールには触らない
- 結果のファイルの `Number of entries` が、1 の件数と同じであること
- 空にしてから入れ直すまでの 1 秒もかからない間、日本からの接続も捨てられる（利用の少ない時間帯に流す）
- **この時点では、再起動すると古い一覧に戻る**（起動時に読み込むファイルは、まだ古い中身のまま）。次の 4 も流す

**4. 対象のサーバーで、ipset の集合の今の中身を、起動時に読み込むファイルに保存し直す**

ステップ 5 の `05-persist-ipv4.sh` の中の、次の 2 行と同じことをする。

```bash
sudo -n sh -c 'ipset save port_guard_jp > /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_allow >> /etc/port-guard/ipset-ipv4.save'
```

1 行目で日本の範囲を書き出してファイルを**作り直し**（`>`）、2 行目で許可する IP アドレスを**書き足す**（`>>`）。1 つのファイルに 2 つの集合が入っているので、日本の範囲だけを変えたときも、**2 行とも流す**（1 行目だけだと、許可する IP アドレスがファイルから消え、再起動の後に VPC の中などからの通信が捨てられる）。

この 2 行だけのファイルを、踏み台サーバーの `command/port_guard/save-ipv4.sh`（と `save-ipv6.sh`）として置き、ほかのステップと同じ形で流す。

`command/port_guard/save-ipv4.sh`:

```bash
#!/bin/bash
# 集合の今の中身を、起動時に読み込むファイルに保存し直す（05-persist-ipv4.sh の ipset save の 2 行と同じ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') save-ipv4"

sudo -n sh -c 'ipset save port_guard_jp > /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_allow >> /etc/port-guard/ipset-ipv4.save'

# 確認
grep -c '^add port_guard_jp ' /etc/port-guard/ipset-ipv4.save || true      # 日本の範囲の件数（3 の Number of entries と同じ）
grep -c '^add port_guard_allow ' /etc/port-guard/ipset-ipv4.save || true   # 許可する IP アドレスの件数
```

`command/port_guard/save-ipv6.sh`（IPv6 も絞っている台だけ）:

```bash
#!/bin/bash
# 集合の今の中身を、起動時に読み込むファイルに保存し直す（05-persist-ipv6.sh の ipset save の 2 行と同じ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') save-ipv6"

sudo -n sh -c 'ipset save port_guard_jp6 > /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_allow6 >> /etc/port-guard/ipset-ipv6.save'

# 確認
grep -c '^add port_guard_jp6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_allow6 ' /etc/port-guard/ipset-ipv6.save || true
```

流し方:

```bash
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/save-ipv4.sh >> ./output/result.txt
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/save-ipv6.sh >> ./output/result.txt   # IPv6 も絞っている台だけ
```

`save-ipv4.sh` の代わりに、`05-persist-ipv4.sh` を丸ごと流し直してもよい（保存の 2 行に加えて、起動時のコマンドの並びのファイルを同じ中身で置き直すだけ）。ステップ 6 まで流していない（永続化していない）台では、4 は要らない。

### 許可する IP アドレスの一覧を変えるとき

VPC の範囲を足した、許可する相手が増えた・減ったなどのとき。日本の範囲の一覧（上の 1）は作り直さなくてよい。

1. 踏み台サーバーで、`port_guard_whitelists/allow-ipv4.txt`（と `allow-ipv6.txt`）を書き直す（ステップ 0-2）
2. 踏み台サーバーで、ステップ 3-1 のうち許可する IP アドレスの行で、ファイルを作り直す（カレントのフォルダで）

```bash
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv4.txt | awk 'NF { print "add port_guard_allow " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow'; } > command/port_guard/03-allow-ipv4.sh

# IPv6 も絞っている台があるときだけ
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv6.txt | awk 'NF { print "add port_guard_allow6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow6'; } > command/port_guard/03-allow-ipv6.sh
```

3. 踏み台サーバーにある今のスクリプトで各サーバーに流して、ipset の集合の中身を入れ替える

```bash
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/03-allow-ipv4.sh >> ./output/result.txt
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/03-allow-ipv6.sh >> ./output/result.txt   # IPv6 も絞っている台だけ
```

4. 対象のサーバーで、起動時に読み込むファイルに保存し直す（上の 4 と同じ `save-ipv4.sh`（と `save-ipv6.sh`））

## IPv4・IPv6 を後から外す・足す

| したいこと | すること |
|---|---|
| IPv6 を、起動時に入れないようにする | `sudo -n rm /etc/systemd/system/port-guard.service.d/20-ipv6.conf` と `sudo -n systemctl daemon-reload`（今入っている IPv6 のルールは、ステップ 4 の「うまくいかなかったときに外す」を `ip6tables` で流して外す） |
| IPv6 を後から足す | IPv6 のステップ 2〜4（`-ipv6.sh`）の後に、`05-persist-ipv6.sh` を流す（ステップ 6 は流し直さなくてよい） |

## サービスの確認・停止・起動時の無効化・アンインストール

ステップ 6 で置いたサービス `port-guard.service` と、カーネルの中のルール・集合を、確かめる・止める・外すためのコマンド。どれも、ほかのステップと同じ形（踏み台サーバーから `ssh ... 'bash' < ./command/port_guard/<ファイル>.sh`）で流す。

| したいこと | ファイル | 80・443 番の絞り込み | 次の起動のとき |
|---|---|---|---|
| 状態を見る（読み取りだけ） | `command/port_guard/status.sh` | 変わらない | 変わらない |
| 今だけ止める | `command/port_guard/stop.sh` | **外れる**（カーネルの `INPUT` チェーンから、`PORT_GUARD` へ飛ばすルールを削除する） | サービスが有効なら、また入る |
| 起動時に動かないようにする | `command/port_guard/disable.sh` | 変わらない（今入っているルールはそのまま） | **入らない** |
| サービスを取り除く（アンインストール） | `command/port_guard/uninstall.sh` | **外れる** | **入らない**（サービスのファイルがなくなる） |
| ルール・集合・保存のファイルも全部消す | `command/port_guard/purge.sh`（`uninstall.sh` の後に） | 外れたまま | 入らない |

**`systemctl stop` だけでは、絞り込みは外れない**。このサービスは、起動時にコマンドの並びを 1 回流して終わる形（`Type=oneshot`）で、止めるときに動かすコマンド（`ExecStop=`）を持っていない。`systemctl stop` は、サービスの表示を「止まっている（`inactive`）」にするだけで、カーネルの中のルールと集合はそのまま残り、絞り込みは効き続ける。そのため、`stop.sh` と `uninstall.sh` では、`systemctl stop` の後に、iptables のコマンドでルールの削除も行う。

`stop.sh`・`uninstall.sh`・`purge.sh` では、消す相手がないとき（IPv6 を絞っていない台、すでに消してあるときなど）に、`iptables: Bad rule (does a matching rule exist in that chain?).` などのメッセージが結果のファイルに出る。`|| true` で先へ進むので、問題はない（最後の「確認」の数が 0 になっていればよい）。

止めた後にもう一度効かせるときは、`sudo systemctl start port-guard`（ステップ 5 のコマンドの並びがもう一度流れる。何度流しても同じ状態になる書き方なので、二重には入らない）。

### 状態を見る（`command/port_guard/status.sh`）

```bash
#!/bin/bash
# port-guard のサービスと、カーネルの中のルール・集合の状態を見る（読み取りだけ。何も変えない）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') status"

echo "-- サービス"
systemctl is-enabled port-guard 2>&1 || true        # enabled（起動時に動く）/ disabled（動かない）/ ファイルがなければエラー
systemctl is-active port-guard 2>&1 || true         # active（入れた）/ inactive（止まっている）/ failed（途中で失敗した）
ls -l /etc/systemd/system/port-guard.service /etc/systemd/system/port-guard.service.d/ 2>&1 || true
sudo -n journalctl -b -u port-guard --no-pager 2>&1 | tail -20 || true   # 今回の起動での、このサービスの記録

echo "-- カーネルの中のルール（INPUT から PORT_GUARD へ飛ばすルール）"
sudo -n iptables -w 10 -S INPUT | grep -- '-j PORT_GUARD' || echo "IPv4: なし"
sudo -n ip6tables -w 10 -S INPUT | grep -- '-j PORT_GUARD' || echo "IPv6: なし"

echo "-- カーネルの中の集合"
sudo -n ipset list -t 2>&1 | grep -E '^(Name|Number of entries|References):' || echo "集合: なし"
```

| 見ること | 内容 |
|---|---|
| `is-enabled` | `enabled` なら、次の起動で入る。`disabled` なら入らない |
| `is-active` | `active` ならサービスが流れ終わっている。`failed` なら途中のコマンドで失敗している（`journalctl` の記録で、どのコマンドかを見る）。`inactive` は止めた後か、まだ流していない |
| `INPUT` から `PORT_GUARD` へ飛ばすルール | `-A INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD` が出れば、**今、絞り込みが効いている**。サービスの表示（`is-active`）ではなく、ここで判断する |
| 集合 | `port_guard_jp` の `Number of entries` が数千件、`References` が 1（ルールから参照されている）なら、普通の状態 |

### 今だけ止める（`command/port_guard/stop.sh`）

```bash
#!/bin/bash
# port-guard を今だけ止める: サービスを止め、カーネルの INPUT チェーンから PORT_GUARD へ飛ばすルールを削除する（80・443 番の絞り込みが外れる）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') stop"

sudo -n systemctl stop port-guard
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true    # ルールがなければ失敗するので || true
sudo -n ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true   # IPv6 を絞っていない台では失敗するので || true

# 確認
systemctl is-active port-guard || true                                    # inactive
sudo -n iptables -w 10 -S INPUT | grep -c -- '-j PORT_GUARD' || true      # 0
sudo -n ip6tables -w 10 -S INPUT | grep -c -- '-j PORT_GUARD' || true     # 0
```

- `PORT_GUARD` チェーンと集合は残るが、どこからも飛んでこないので何もしない
- 起動時の設定（`enable`）は変えないので、**次の再起動でまた入る**。再起動の後も入れたくないなら、続けて `disable.sh` も流す
- もう一度効かせるときは `sudo systemctl start port-guard`

### 起動時に動かないようにする（`command/port_guard/disable.sh`）

```bash
#!/bin/bash
# port-guard を、次の起動から動かないようにする（今入っているルールはそのまま）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') disable"

sudo -n systemctl disable port-guard

# 確認
systemctl is-enabled port-guard || true   # disabled
```

- 今効いている絞り込みは外れない。今も外すなら、`stop.sh` も流す
- 元に戻すときは `sudo systemctl enable port-guard`（ステップ 6 の `enable` と同じ）

### サービスを取り除く（`command/port_guard/uninstall.sh`）

```bash
#!/bin/bash
# port-guard のサービスを取り除く: 止めて、起動時に動かないようにし、サービスのファイルを削除する
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') uninstall"

sudo -n systemctl stop port-guard || true                       # サービスがなければ失敗するので || true
sudo -n systemctl disable port-guard || true
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true
sudo -n ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true

sudo -n rm -f /etc/systemd/system/port-guard.service                          # サービスの本体（ステップ 6）
sudo -n rm -rf /etc/systemd/system/port-guard.service.d                       # 起動時のコマンドの並び（ステップ 5 の 10-ipv4.conf・20-ipv6.conf）
sudo -n systemctl daemon-reload
sudo -n systemctl reset-failed port-guard 2>/dev/null || true   # 失敗の記録が残っていれば消す

# 確認
ls /etc/systemd/system/ | grep port-guard || echo "サービスのファイル: なし"
sudo -n iptables -w 10 -S INPUT | grep -c -- '-j PORT_GUARD' || true      # 0
```

| 消すもの | 残るもの |
|---|---|
| サービスの本体（`/etc/systemd/system/port-guard.service`）と、起動時のコマンドの並び（`/etc/systemd/system/port-guard.service.d/`）。カーネルの `INPUT` チェーンから `PORT_GUARD` へ飛ばすルール | `PORT_GUARD` チェーンと集合（カーネルの中。どこからも使われないので何もしない。再起動すると消える）、保存のファイル（`/etc/port-guard/`）、入れる前のルールの控え（`/var/lib/port-guard/`）、ipset のパッケージ |

もう一度入れるときは、ステップ 5・6 を流し直す（再起動していなければ、集合は残っているので、ステップ 2〜4 は要らない。ただし `PORT_GUARD` へ飛ばすルールは消えているので、`sudo systemctl start port-guard` で入れ直す）。

### iptables のルール・ipset の集合・保存のファイルも全部消す（`command/port_guard/purge.sh`）

`uninstall.sh` の後に、カーネルの中に残った `PORT_GUARD` チェーンと集合、保存のファイルも消して、入れる前の状態に戻すとき。

```bash
#!/bin/bash
# uninstall.sh の後に流す。カーネルの中の PORT_GUARD チェーンと集合、保存のファイルを消す
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') purge"

# カーネルの中のルール（INPUT から飛ばすルールを先に削除してから、チェーンを空にして消す）
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true
sudo -n iptables -w 10 -F PORT_GUARD || true
sudo -n iptables -w 10 -X PORT_GUARD || true
sudo -n ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true
sudo -n ip6tables -w 10 -F PORT_GUARD || true
sudo -n ip6tables -w 10 -X PORT_GUARD || true

# カーネルの中の集合（ルールから参照されていると消せないので、ルールの後に消す）
sudo -n ipset destroy port_guard_jp || true
sudo -n ipset destroy port_guard_allow || true
sudo -n ipset destroy port_guard_jp6 || true
sudo -n ipset destroy port_guard_allow6 || true

# 保存のファイル（入れる前のルールの控え /var/lib/port-guard/ は、記録として残す）
sudo -n rm -rf /etc/port-guard

# 確認
sudo -n iptables -w 10 -S | grep -c PORT_GUARD || true    # 0
sudo -n ip6tables -w 10 -S | grep -c PORT_GUARD || true   # 0
sudo -n ipset list -n | grep -c port_guard || true        # 0
```

- 各行の `|| true` は、IPv6 を絞っていない台など、消す相手がないときに止まらないため
- ipset のパッケージ（ステップ 1）は消さない（ほかで使っていないと分かっていれば `sudo yum remove ipset`）

## 補足

長い前置き（仕組みの説明）、運用の仕組みの設計、手元で確かめたこと、自動化の道具との違いは [補足](./bastion-install-supplement.md)。
