# 踏み台サーバーから対象のサーバーに iptables と ipset を入れて、80・443 番の受け付けを日本と許可した IP アドレスに絞る手順（コマンドの一覧）

> 位置付け: 踏み台サーバーから SSH で、対象のサーバー（Amazon Linux 2 の Web サーバー）に iptables と ipset の設定を入れるためのコマンドを、ステップごとのファイルにまとめたもの。どのファイルも、**上から順に実行するコマンドを並べただけ**（関数や、条件で分ける処理は使わない）。複数台に流すのは、踏み台サーバーにある今のスクリプトで行う。
>
> このドキュメントは**手順とコマンド、各ステップの説明、結果の見方**を書いている。長い前置き（Linux・iptables・ipset・systemd などを知らない人向けの仕組みの説明）、運用の仕組みの設計（Let's Encrypt の更新・一覧の定期の更新）、手元で確かめたこと、自動化の道具との違いは [補足](./bastion-install-supplement.md) にまとめている。各ステップの説明と、コマンドの 1 行ずつの意味は、このドキュメントの各ステップにある。
>
> 状態: 対象のサーバー（Amazon Linux 2）ではまだ流していない。Let's Encrypt の更新への対応はステップ 7 に用意した（手元の偽物のコマンドでだけ確かめた）。一覧の更新は `make-refresh.sh`（「一覧を新しくするとき」）に用意した。**本番に流す前に確認が要ることは [確認すること](./confirmation-items.md) にまとめている**。
>
> 更新日: 2026-11-11

## このドキュメントで行うこと

対象のサーバーが受け付ける **80 番（HTTP）と 443 番（HTTPS）の通信を、次の 2 つから来たものだけ**にする。それ以外から来た 80・443 番の通信は捨てる。**22 番（SSH）は絞らない**。

- 日本に割り当てられた IP アドレス（APNIC が公開している一覧から作る）
- 許可する IP アドレス（**対象のサーバーが入っている VPC の範囲**と、日本の外から受ける必要がある相手）
- AWS の東京（`ap-northeast-1`）と大阪（`ap-northeast-3`）のリージョンの範囲（AWS が公開している一覧から作る。リージョンを丸ごと許可する。ステップ 0-3）

| 注意 | 内容 |
|---|---|
| **Let's Encrypt の証明書の更新** | certbot で証明書を更新している台は、この手順を入れると、そのままでは更新が失敗する（海外からの確認の接続が捨てられる）。**ステップ 7（更新の間だけ 80 番を開ける hook）もあわせて流す** |
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
| ファイルの置き場所（踏み台サーバー） | 踏み台サーバーのカレントのフォルダの下に置く。**`command/` の直下には、踏み台サーバーで実行するものだけ**（ステップ 0-1 の `make-jp-lists.sh`、ステップ 0-3 の `make-aws-lists.sh`、ステップ 3-1 の `make-ipset-files-ipv4.sh`・`make-ipset-files-ipv6.sh`、一覧を新しくするときの `make-refresh.sh`、証明書の期限の確認の `cert-expiry-check.sh`）。**`command/port_guard/` の下には、対象のサーバーに送るものだけ**（ステップ 0-2 の `00-vpc-cidr.sh`、ステップ 1〜6、ステップ 3 で作る `03-*.sh`、ステップ 7 の `07-letsencrypt-*.sh`、一覧を新しくするときに作る `refresh-ipv4.sh`・`refresh-ipv6.sh`、保存し直しの `save-ipv4.sh`・`save-ipv6.sh`、サービスの確認・停止・無効化・アンインストールの `status.sh`・`stop.sh`・`disable.sh`・`uninstall.sh`・`purge.sh`）。踏み台サーバーで実行するものは、カレントのフォルダで `bash command/<ファイル>.sh` と実行する（中で使う `port_guard_whitelists/` と `command/port_guard/` は、カレントのフォルダから見た場所）。一覧は `port_guard_whitelists/` |
| 日本の範囲の一覧を作る場所 | **踏み台サーバー**（IPv4 と IPv6）。対象のサーバーは APNIC に取りに行かない（対象のサーバーに `curl`・`python3` は要らない） |
| 一覧の渡し方 | 一覧を、ステップ 3 のファイルの中に `ipset` に読ませる行（`add <集合> <範囲>`）として並べて送る。そのファイルは、踏み台サーバーで一覧から `command/make-ipset-files-ipv4.sh`（IPv6 は `-ipv6.sh`）で作る |
| 実行する人 | `centos`。`root` の権限が要るコマンドは `sudo -n` |
| 絞るポート | 80・443 番。22 番は絞らない |
| IPv6 | 対象のサーバーに IPv6 のアドレスがあり、セキュリティグループで IPv6 の 80・443 番を通しているときだけ要る。**IPv6 の分は、どのステップも別のファイル**（名前が `-ipv6.sh` で終わるもの）にしているので、IPv6 を絞らないなら流さない |

### IPv4 と IPv6 は、ファイルも ipset の集合も分ける

| 種類 | 踏み台サーバーの一覧 | ipset の集合の名前（型） | 再起動のために保存するファイル（対象のサーバー） |
|---|---|---|---|
| 日本の範囲（IPv4） | `port_guard_whitelists/jp-ipv4.txt` | `port_guard_jp`（`hash:net family inet`） | `/etc/port-guard/ipset-ipv4.save` |
| 許可する IP アドレス（IPv4） | `port_guard_whitelists/allow-ipv4.txt` | `port_guard_allow`（`hash:net family inet`） | `/etc/port-guard/ipset-ipv4.save` |
| AWS の東京と大阪（IPv4） | `port_guard_whitelists/aws-ipv4.txt` | `port_guard_aws`（`hash:net family inet`） | `/etc/port-guard/ipset-ipv4.save` |
| 日本の範囲（IPv6） | `port_guard_whitelists/jp-ipv6.txt` | `port_guard_jp6`（`hash:net family inet6`） | `/etc/port-guard/ipset-ipv6.save` |
| 許可する IP アドレス（IPv6） | `port_guard_whitelists/allow-ipv6.txt` | `port_guard_allow6`（`hash:net family inet6`） | `/etc/port-guard/ipset-ipv6.save` |
| AWS の東京と大阪（IPv6） | `port_guard_whitelists/aws-ipv6.txt` | `port_guard_aws6`（`hash:net family inet6`） | `/etc/port-guard/ipset-ipv6.save` |

一覧のサンプルは、日本の範囲（APNIC の 2026-11-02 の版）を [`samples/apnic-jp-20261102/`](./samples/apnic-jp-20261102/README.md) に、AWS の東京と大阪（`ip-ranges.json` の 2026-11-06 の版）を [`samples/aws-tokyo-osaka-20261106/`](./samples/aws-tokyo-osaka-20261106/README.md) に置いている（取り直した一覧と比べて、大きく変わっていないかを見るのに使える）。

### ステップの一覧

**どのステップが要るか**

| 入れ方 | 流すステップ | 再起動すると |
|---|---|---|
| **設定だけ（永続化しない）** | 0 → 1 → 2 → 3 → 4 | 集合もルールも消えて、80・443 番の絞り込みが外れる（元の状態に戻る）。もう一度効かせるには、ステップ 2 から流し直す（下の「注意」） |
| **永続化する** | 0 → 1 → 2 → 3 → 4 → 5 → 6 | 起動のたびに、サービスが集合とルールを入れ直す（絞り込みが効いたまま） |
| **Let's Encrypt の証明書を certbot で更新している台**（上のどちらでも） | 上に加えて 7 | 証明書の更新の間だけ 80 番が開く。**ステップ 4 を流したら、間を空けずに同じ作業の中で 7 を流す**（流さないと更新が失敗する） |

- 設定だけは、試しに入れて様子を見るとき向け。問題があっても、再起動すれば元に戻る
- 永続化するときも、ステップ 4 まで流して結果（日本からつながる・海外から止まる）を確かめてから、ステップ 5・6 を流す
- 設定だけで入れた台を後から永続化するなら、ステップ 5・6 を足して流すだけでよい（再起動していなければ、ステップ 0〜4 は流し直さなくてよい）
- IPv6 も絞る台は、ステップ 2〜5 の `-ipv6.sh` も流す（ステップ 0・1・6 は IPv4・IPv6 で共通）

| ステップ | どこで | ファイル | すること | このステップの後の状態 |
|---|---|---|---|---|
| 0 | 踏み台サーバー（VPC の範囲を調べるときだけ対象のサーバー） | `command/make-jp-lists.sh`・`command/make-aws-lists.sh`・`command/port_guard/00-vpc-cidr.sh` | 踏み台サーバーが、APNIC の一覧から日本の IPv4・IPv6 の範囲の一覧を、AWS の一覧から東京と大阪の範囲の一覧を作る。許可する IP アドレスの一覧（VPC の範囲を含む）を作業者が書く | 対象のサーバーは何も変わらない |
| 1 | 対象のサーバー | `command/port_guard/01-install.sh` | 対象のサーバーに ipset を入れ、邪魔になるものがないかを確かめる（iptables は最初から入っている） | 通信は今までどおり |
| 2 | 対象のサーバー | `command/port_guard/02-sets-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーに、ipset の空の集合を作る | 通信は今までどおり |
| 3 | ファイルを作るスクリプト（`command/make-ipset-files-ipv4.sh`）は踏み台サーバーで実行し、作られたファイルは踏み台サーバーにある今のスクリプトで各サーバーに流す | `command/port_guard/03-jp-ipv4.sh`・`03-allow-ipv4.sh`・`03-aws-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーの ipset の集合に、一覧を入れる | 通信は今までどおり（ipset の集合はルールから参照されるまで何もしない） |
| 4 | 対象のサーバー | `command/port_guard/04-rules-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーに iptables のルールを入れる | **ここから 80・443 番の絞り込みが効く**（再起動すると消える） |
| 5 | 対象のサーバー | `command/port_guard/05-persist-ipv4.sh`（IPv6 は `-ipv6.sh`） | 対象のサーバーで、ipset の集合をファイルに保存し、起動時に入れ直すコマンドの並びを置く | 再起動するとまだ消える（ステップ 6 で有効にする） |
| 6 | 対象のサーバー | `command/port_guard/06-service.sh` | 対象のサーバーに、起動時に動くサービス `port-guard.service` を置いて有効にする | **再起動の後も効く** |
| 7 | 対象のサーバー（certbot で証明書を更新している台だけ） | `command/port_guard/07-letsencrypt-check.sh`・`07-letsencrypt-hooks.sh` | certbot の hook を置き、証明書の更新の間だけ 80 番を開けるようにする | 証明書の更新の間（数秒〜数分）だけ、80 番がどこからでも通る。443 番は絞ったまま |

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
2. `03-jp-ipv4.sh`・`03-allow-ipv4.sh`・`03-aws-ipv4.sh`（ipset の集合に一覧を入れる。前に作ったファイルをそのまま使える。ステップ 0 と、ステップ 3 のファイルの作り直しは、一覧を新しくしたいときだけ）
3. `04-rules-ipv4.sh`（ルールを入れる。ここで絞り込みが効く）
4. 再起動の後も残すなら、`05-persist-ipv4.sh` と `06-service.sh`

ステップ 2 と 3 は飛ばせない。ステップ 4 のルールは集合を名前で参照するので、集合がないとルールを入れられずに失敗する。また、ステップ 4 は日本の集合が 1,000 件（IPv6 は 200 件）未満だと止まる。

## ステップ 0: 踏み台サーバーで、日本の範囲の一覧・許可する IP アドレスの一覧・AWS の東京と大阪の範囲の一覧を作る

### 0-1. 踏み台サーバーが、日本の IP アドレスの範囲の一覧を作る

踏み台サーバーが APNIC の一覧を取り、日本（`JP`）の行だけを取り出して、1 行 1 件の範囲の一覧（TSV。1 列目が CIDR、2 列目以降が情報。ステップ 0-3 の後の「一覧のファイルの形」）にする。`awk`（行ごとに文字列を加工するコマンド。どの Linux にも入っている）だけで行うので、踏み台サーバーに Python は要らない。

- **IPv6** は「先頭のアドレス」と「CIDR の長さ」で書かれているので、`/` でつなぐだけで CIDR になる（例: `2001:200::` と `35` → `2001:200::/35`）
- **IPv4** は「先頭のアドレス」と「個数」で書かれている。個数は 2 のべき乗（256、512、1024…）とは限らないので、CIDR で書ける区切りに分ける。例: 先頭 `10.0.0.0`・個数 768 → `10.0.0.0/23`（512 個）と `10.0.2.0/24`（256 個）。下の `while` の部分が、この分け方をしている（先頭から、区切りのよい、なるべく大きな塊を切り出していく）

`command/make-jp-lists.sh`（踏み台サーバーのカレントのフォルダで `bash command/make-jp-lists.sh` と実行する）:

```bash
#!/bin/bash
# 踏み台サーバーで実行する。APNIC の割り当ての統計から、日本の IPv4・IPv6 の範囲の一覧（TSV）を port_guard_whitelists/ に作る
set -euo pipefail
mkdir -p port_guard_whitelists
curl -fsS --max-time 120 -o port_guard_whitelists/delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest

# 元の版（版の行の 3 番目の項目。例: 20261102）
VERSION=$(awk -F'|' '$1 ~ /^[0-9]/ && $2 == "apnic" { print $3; exit }' port_guard_whitelists/delegated-apnic-latest)

# IPv4: 先頭のアドレスと個数を、CIDR に分ける。2 列目以降は、国・割り当ての組織・状態・割り当ての日
awk -F'|' -v version="$VERSION" '
function ip2n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
function n2ip(n) { return sprintf("%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256) }
BEGIN { print "# source: APNIC delegated-apnic-latest " version; print "# cidr\tcountry\tregistry\tstatus\tdate" }
$2 == "JP" && $3 == "ipv4" && ($7 == "allocated" || $7 == "assigned") {
  start = ip2n($4); count = $5
  while (count > 0) {
    size = 1; bits = 32
    while (size * 2 <= count && start % (size * 2) == 0) { size *= 2; bits-- }
    print n2ip(start) "/" bits "\t" $2 "\t" $1 "\t" $7 "\t" $6
    start += size; count -= size
  }
}' port_guard_whitelists/delegated-apnic-latest > port_guard_whitelists/jp-ipv4.txt

# IPv6: 先頭のアドレスと長さを、そのまま CIDR にする
awk -F'|' -v version="$VERSION" '
BEGIN { print "# source: APNIC delegated-apnic-latest " version; print "# cidr\tcountry\tregistry\tstatus\tdate" }
$2 == "JP" && $3 == "ipv6" && ($7 == "allocated" || $7 == "assigned") { print $4 "/" $5 "\t" $2 "\t" $1 "\t" $7 "\t" $6 }' \
  port_guard_whitelists/delegated-apnic-latest > port_guard_whitelists/jp-ipv6.txt

echo "APNIC の版: ${VERSION}、IPv4: $(grep -vc '^#' port_guard_whitelists/jp-ipv4.txt) 件、IPv6: $(grep -vc '^#' port_guard_whitelists/jp-ipv6.txt) 件"
```

| 行 | 意味 |
|---|---|
| `curl -fsS --max-time 120 -o <ファイル> <URL>` | APNIC の一覧を取ってファイルに保存する。`-f` は、取れなかったとき（サーバーのエラー）に失敗を返す。`--max-time 120` は 120 秒で諦める |
| `awk -F'|' '...'` | 各行を `|` で区切り、`$2`（2 番目）・`$3`・`$4`… で項目を参照する。条件に合う行だけを処理する |
| `ip2n`・`n2ip` | IPv4 のアドレスと数とを行き来する計算（`1.0.16.0` ↔ 16,781,312）。範囲を数として扱って区切るため |
| `VERSION=$(awk ... { print $3; exit })` | APNIC の一覧の版の行（`2|apnic|20261102|...`）から、版（日付）を取り出す。一覧の先頭のコメントに書く |
| `BEGIN { print "# ..." }` | 一覧の先頭に、元の版と、列の名前を、コメントの行（`#` で始まる）として書く |
| `"\t" $2 "\t" $1 "\t" $7 "\t" $6` | 範囲の後ろに、タブで区切って、国（`JP`）・割り当ての組織（`apnic`）・状態・割り当ての日を書く |
| `${VERSION}`・`grep -vc '^#'` | 版を表示する（`${...}` と括るのは、後ろに続く日本語の文字を変数の名前と取り違えないため）。コメントの行を除いた行数（件数）を数える |

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
| 同じリージョンの Lambda・Fargate から呼ばれる通信（あれば） | 送り元は、Lambda・Fargate が VPC の中にいるかと、サーバーのどのアドレスあてに接続するかで変わる。VPC の中からプライベートのアドレスあてなら VPC の範囲で通る。公開のアドレスあてなら NAT ゲートウェイの Elastic IP を書く。VPC に入れていない Lambda は送り元を固定できない。詳しくは [同じリージョンの Lambda・Fargate からサーバーを呼ぶとき、送り元はどこになるか](./access-sources-lambda-fargate.md) |

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
| `IMDS=http://169.254.169.254` | インスタンスメタデータサービスの入り口を、名前（`IMDS`）を付けた変数にしておく。以降の問い合わせは `$IMDS/...` と書く。AWS はこの仕組みに DNS の名前を用意しておらず、AWS のドキュメントもアドレスで案内している（[補足](./bastion-install-supplement.md) の「ステップ 0-2」） |
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

インスタンスメタデータから調べる理由と、AWS のドキュメントとの照らし合わせは [補足](./bastion-install-supplement.md) の「ステップ 0-2」。

**VPC の範囲を丸ごと許可するのは、VPC の中を信頼する前提**。VPC の中の特定のサーバーからだけ受けたいなら、VPC の範囲の代わりに、そのサーバーのプライベートのアドレスを 1 件ずつ書く（ただし、踏み台サーバーからの確認もそのアドレスを書かないと止まる）。

### 0-3. 踏み台サーバーが、AWS の東京と大阪のリージョンの範囲の一覧を作る

AWS が公開している IP アドレスの範囲の一覧（`ip-ranges.json`。約 2.7 MB）を取り、**東京（`ap-northeast-1`）と大阪（`ap-northeast-3`）のリージョン**の範囲だけを取り出して、一覧（TSV）にする。この一覧は、ipset の別の集合（`port_guard_aws`・`port_guard_aws6`）に入れ、`PORT_GUARD` チェーンの別のルールで通す（日本の範囲や、手で書く許可の一覧とは分けて管理する）。

分けて管理する理由は [補足](./bastion-install-supplement.md) の「ステップ 0-3」。

**注意: リージョンを丸ごと許可する**。この範囲には、AWS の東京・大阪を使う**すべての利用者**（他社の EC2・Lambda・NAT ゲートウェイなど）が入る。東京か大阪に EC2 を借りれば、誰でも通れる。実際に呼んでくる相手が分かったら（[API のアクセス元の洗い出し](../api-access-sources/design.md)）、その相手だけを許可の一覧（0-2）に書く形に狭めることを考える。

`command/make-aws-lists.sh`（踏み台サーバーのカレントのフォルダで `bash command/make-aws-lists.sh` と実行する）:

```bash
#!/bin/bash
# 踏み台サーバーで実行する。AWS の IP アドレスの範囲の一覧（ip-ranges.json）から、東京・大阪のリージョンの範囲の一覧（TSV）を port_guard_whitelists/ に作る
set -euo pipefail
mkdir -p port_guard_whitelists
curl -fsS --max-time 120 -o port_guard_whitelists/ip-ranges.json https://ip-ranges.amazonaws.com/ip-ranges.json

# 取り出す条件
REGIONS='ap-northeast-1 ap-northeast-3'          # 東京・大阪
SERVICE='AMAZON'                                 # AWS の全部のサービスを含む区分
EXCLUDE_BORDER_GROUPS='ap-northeast-1-tpe-1'     # 東京リージョンの中でも日本の外にあるもの（台北のローカルゾーン）

# 元の版（ip-ranges.json の createDate）
CREATED=$(awk -F'"' '$2 == "createDate" { print $4; exit }' port_guard_whitelists/ip-ranges.json)

# IPv4（"ip_prefix"）。1 つの範囲は { から } までの数行で、1 行に 1 つの項目がある
awk -F'"' -v key=ip_prefix -v regions="$REGIONS" -v service="$SERVICE" -v exclude="$EXCLUDE_BORDER_GROUPS" -v created="$CREATED" '
BEGIN { n = split(regions, a, " "); for (i = 1; i <= n; i++) R[a[i]] = 1
        n = split(exclude, b, " "); for (i = 1; i <= n; i++) X[b[i]] = 1
        print "# source: AWS ip-ranges.json createDate " created; print "# cidr\tregion\tservice\tnetwork_border_group" }
$2 == key { p = $4 }
$2 == "region" { r = $4 }
$2 == "service" { s = $4 }
$2 == "network_border_group" { g = $4 }
/^[[:space:]]*}/ { if (p != "" && (r in R) && s == service && !(g in X)) print p "\t" r "\t" s "\t" g; p = r = s = g = "" }' \
  port_guard_whitelists/ip-ranges.json > port_guard_whitelists/aws-ipv4.txt

# IPv6（"ipv6_prefix"）
awk -F'"' -v key=ipv6_prefix -v regions="$REGIONS" -v service="$SERVICE" -v exclude="$EXCLUDE_BORDER_GROUPS" -v created="$CREATED" '
BEGIN { n = split(regions, a, " "); for (i = 1; i <= n; i++) R[a[i]] = 1
        n = split(exclude, b, " "); for (i = 1; i <= n; i++) X[b[i]] = 1
        print "# source: AWS ip-ranges.json createDate " created; print "# cidr\tregion\tservice\tnetwork_border_group" }
$2 == key { p = $4 }
$2 == "region" { r = $4 }
$2 == "service" { s = $4 }
$2 == "network_border_group" { g = $4 }
/^[[:space:]]*}/ { if (p != "" && (r in R) && s == service && !(g in X)) print p "\t" r "\t" s "\t" g; p = r = s = g = "" }' \
  port_guard_whitelists/ip-ranges.json > port_guard_whitelists/aws-ipv6.txt

echo "ip-ranges.json の版: ${CREATED}、IPv4: $(grep -vc '^#' port_guard_whitelists/aws-ipv4.txt) 件、IPv6: $(grep -vc '^#' port_guard_whitelists/aws-ipv6.txt) 件"
```

| 行 | 意味 |
|---|---|
| `curl ... ip-ranges.json` | AWS の範囲の一覧を取る（`https://ip-ranges.amazonaws.com/ip-ranges.json`） |
| `REGIONS='ap-northeast-1 ap-northeast-3'` | 取り出すリージョン（東京・大阪）。空白で区切って並べる |
| `SERVICE='AMAZON'` | 取り出すサービスの区分。`ip-ranges.json` では、同じ範囲が全体の `AMAZON` と、個別の `EC2`・`S3` などに重ねて載る。`AMAZON` は全部を含む（2026-11-06 の版で、東京・大阪の個別のサービスの範囲が、IPv4・IPv6 とも、すべて `AMAZON` の範囲に含まれることを確かめた） |
| `EXCLUDE_BORDER_GROUPS='ap-northeast-1-tpe-1'` | 除くもの。`ap-northeast-1-tpe-1` は、東京リージョンに属する**台北（台湾）のローカルゾーン**で、日本の外にある（2026-11-06 の版で IPv4 の 2 件）。空にすれば除かない |
| `awk -F'"' ...` | `ip-ranges.json` は、1 つの範囲が `{` から `}` までの数行で、1 行に 1 つの項目（`"ip_prefix": "...",` など）が書かれている。`"` で区切って、項目の名前（`$2`）と値（`$4`）を読み、`}` の行で、条件に合えば 1 行を書く。IPv4 は `ip_prefix`、IPv6 は `ipv6_prefix` |
| `CREATED=...` | 一覧の版（`createDate`）。一覧の先頭のコメントに書く |

| 点 | 内容 |
|---|---|
| 件数の目安 | 2026-11-06 の版で IPv4 305 件、IPv6 149 件（台北を除いた後） |
| 確かめたこと | 2026-11-06 の版で、この `awk` の結果が、Python の JSON の読み込みで同じ条件で取り出したものと、全件同じだった |
| 形が変わったら | AWS が `ip-ranges.json` の書き方（1 行に 1 項目）を変えると、取り出せなくなる。件数が 0 や大きく減ったときは、ファイルの中を見て確かめる |
| 更新の頻度 | AWS は、この一覧を随時更新する。日本の範囲の一覧と同じく、一覧を新しくするときに流し直す（後の「一覧を新しくするとき」） |
| 大阪のほかのゾーン | `network_border_group` には、Wavelength（通信事業者の網の中の区画）の東京・大阪（`ap-northeast-1-wl1-nrt-wlz-1`・`ap-northeast-1-wl1-kix-wlz-1`）も入る。どちらも日本の中にあるので、除いていない |

### 一覧のファイルの形（TSV）

`port_guard_whitelists/` の一覧は、どれも同じ形で読む。

```
# source: AWS ip-ranges.json createDate 2026-11-06-01-07-05
# cidr	region	service	network_border_group
15.152.0.0/16	ap-northeast-3	AMAZON	ap-northeast-3
```

| 決まり | 内容 |
|---|---|
| 1 列目 | 範囲（CIDR。1 つのアドレスなら `/32` を省略してよい）。**ipset に入れるのはこの列だけ** |
| 2 列目以降 | 情報（タブか空白で区切る）。あってもなくてもよい。ipset に入れるときは削られる |
| `#` から後 | コメント。`#` で始まる行も、行の途中の `#` から後も無視される |
| 空の行 | 無視される |

| 一覧 | 2 列目以降の情報 |
|---|---|
| `jp-ipv4.txt`・`jp-ipv6.txt`（0-1） | 国（`JP`）、割り当ての組織（`apnic`）、状態（`allocated`・`assigned`）、割り当ての日 |
| `allow-ipv4.txt`・`allow-ipv6.txt`（0-2） | 自由（誰の・何のアドレスか。書かなくてもよい） |
| `aws-ipv4.txt`・`aws-ipv6.txt`（0-3） | リージョン、サービス、`network_border_group`（ネットワークの区画。ローカルゾーンなどは別の名前になる） |

ipset に入れるファイルを作るステップ 3-1 のスクリプトは、`#` から後を消し（`sed 's/#.*//'`）、空でない行の 1 列目だけ（`awk 'NF { print ... $1 }'`）を使う。そのため、情報の列があってもなくても、同じように読める。

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
sudo -n ipset create -exist port_guard_aws hash:net family inet maxelem 65536

# 確認
sudo -n ipset list -t port_guard_jp
sudo -n ipset list -t port_guard_allow
sudo -n ipset list -t port_guard_aws
```

`command/port_guard/02-sets-ipv6.sh`（IPv6 も絞るときだけ）:

```bash
#!/bin/bash
# IPv6 の空の集合を作る（日本の範囲と、許可する IP）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 02-sets-ipv6"

sudo -n ipset create -exist port_guard_jp6 hash:net family inet6 maxelem 65536
sudo -n ipset create -exist port_guard_allow6 hash:net family inet6 maxelem 65536
sudo -n ipset create -exist port_guard_aws6 hash:net family inet6 maxelem 65536

# 確認
sudo -n ipset list -t port_guard_jp6
sudo -n ipset list -t port_guard_allow6
sudo -n ipset list -t port_guard_aws6
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
| 3-1 | **踏み台サーバー**（カレントのフォルダ。対象のサーバーには送らない） | `command/make-ipset-files-ipv4.sh`（IPv6 も絞るなら `-ipv6.sh` も） | 踏み台サーバーに `command/port_guard/03-jp-ipv4.sh`・`03-allow-ipv4.sh`・`03-aws-ipv4.sh`（IPv6 も絞るなら `03-jp-ipv6.sh`・`03-allow-ipv6.sh`・`03-aws-ipv6.sh`）が作られる |
| 3-3 | **各サーバー**（踏み台サーバーにある今のスクリプトで、複数台に当て込む） | 3-1 で作られた `command/port_guard/03-*.sh` | 各サーバーの ipset の集合に、一覧が入る |

### 3-1. 踏み台サーバーで、ファイルを作る

**踏み台サーバーのカレントのフォルダで**、次のスクリプトを実行する（一覧の `#` から後のコメントと、空の行は除く）。これらは対象のサーバーには送らない。実行すると、対象のサーバーに送るファイルが `command/port_guard/` に作られる。

```bash
bash command/make-ipset-files-ipv4.sh
bash command/make-ipset-files-ipv6.sh   # IPv6 も絞るときだけ
```

`command/make-ipset-files-ipv4.sh`:

```bash
#!/bin/bash
# 踏み台サーバーで実行する。IPv4 の一覧から、対象のサーバーで ipset の集合に一覧を入れるファイル（command/port_guard/03-*-ipv4.sh）を作る
set -euo pipefail
mkdir -p command/port_guard
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv4.txt | awk 'NF { print "add port_guard_jp " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp'; } > command/port_guard/03-jp-ipv4.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv4.txt | awk 'NF { print "add port_guard_allow " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow'; } > command/port_guard/03-allow-ipv4.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_aws'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/aws-ipv4.txt | awk 'NF { print "add port_guard_aws " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_aws'; } > command/port_guard/03-aws-ipv4.sh
echo "作った: command/port_guard/03-jp-ipv4.sh・03-allow-ipv4.sh・03-aws-ipv4.sh"
```

`command/make-ipset-files-ipv6.sh`（IPv6 も絞るときだけ）:

```bash
#!/bin/bash
# 踏み台サーバーで実行する。IPv6 の一覧から、対象のサーバーで ipset の集合に一覧を入れるファイル（command/port_guard/03-*-ipv6.sh）を作る
set -euo pipefail
mkdir -p command/port_guard
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_jp6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/jp-ipv6.txt | awk 'NF { print "add port_guard_jp6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_jp6'; } > command/port_guard/03-jp-ipv6.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_allow6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/allow-ipv6.txt | awk 'NF { print "add port_guard_allow6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_allow6'; } > command/port_guard/03-allow-ipv6.sh
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; echo 'sudo -n ipset flush port_guard_aws6'; echo "sudo -n ipset restore -exist <<'EOF'"; sed 's/#.*//' port_guard_whitelists/aws-ipv6.txt | awk 'NF { print "add port_guard_aws6 " $1 }'; echo 'EOF'; echo 'sudo -n ipset list -t port_guard_aws6'; } > command/port_guard/03-aws-ipv6.sh
echo "作った: command/port_guard/03-jp-ipv6.sh・03-allow-ipv6.sh・03-aws-ipv6.sh"
```

1 行の読み方（`make-ipset-files-ipv4.sh` の日本の範囲の行の例）:

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

3-1 で作られた `command/port_guard/03-jp-ipv4.sh`・`03-allow-ipv4.sh`・`03-aws-ipv4.sh`（IPv6 も絞るなら `03-jp-ipv6.sh`・`03-allow-ipv6.sh`・`03-aws-ipv6.sh` も）を、**踏み台サーバーにある今のスクリプトで、各サーバー上で実行する**（ほかのステップと同じ形。1 台なら `ssh ... 'bash' < ./command/port_guard/03-jp-ipv4.sh >> ./output/result.txt`）。

| 点 | 内容 |
|---|---|
| まだ効かない | ipset の集合は、ステップ 4 の iptables のルールから参照されるまで何もしない。このステップの後も、80・443 番は今までどおり |
| 入っているかを 1 件ずつ確かめる | 対象のサーバーで `sudo ipset test port_guard_jp 1.0.16.1`。入っていれば `is in set` と表示される（終了コード 0） |
| 一覧を作り直したら | ステップ 0 の後に、3-1 のスクリプトでファイルを作り直す |
| 絞り込みが効いた後に流し直すとき | `flush` してから入れ直すまでの短い間（1 秒もかからない）、集合が空になり、日本からの接続も捨てられる。永続化している台では、入れ直した後に `command/port_guard/save-ipv4.sh`（と `save-ipv6.sh`）も流して、起動時に読み込むファイルを保存し直す（後の「中身を入れ替えずに、起動時に読み込むファイルだけを保存し直すとき」）。集合が空になる時間を避けたいなら、後の「一覧を新しくするとき」の `refresh-ipv4.sh` を使う |

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
sudo -n iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws src -j ACCEPT
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
sudo -n ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws6 src -j ACCEPT
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
| `-A PORT_GUARD -m set --match-set port_guard_aws src -j ACCEPT` | 送り元が AWS の東京と大阪の範囲の集合（ステップ 0-3）に入っていれば通す。集合が空なら、このルールは何も通さない（ほかのルールに影響しない） |
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
-A PORT_GUARD -m set --match-set port_guard_aws src -j ACCEPT
-A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
-A PORT_GUARD -j DROP
-A INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
```

| 確かめること | どこで | 内容 |
|---|---|---|
| ルールが入ったか | 結果のファイル | 上の 8 行が表示されること（`PORT_GUARD` チェーンを作った印の 1 行と、その中の 6 つのルール、`INPUT` チェーンの 1 つのルール。`iptables -S` は、カーネルの中のルールを 1 つ 1 行で表示する） |
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

サービスは IPv4・IPv6 で 1 つで、`port-guard.service.d/` の中の `*.conf` を名前の順に読む（置いた分だけ動く）。仕組みと、1 つにまとめた理由は [補足](./bastion-install-supplement.md) の「ステップ 5」。

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
sudo -n sh -c 'ipset save port_guard_aws >> /etc/port-guard/ipset-ipv4.save'

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
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws src -j ACCEPT
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
grep -c '^add port_guard_aws ' /etc/port-guard/ipset-ipv4.save || true   # AWS の東京と大阪の件数
grep -c '^ExecStart=' /etc/systemd/system/port-guard.service.d/10-ipv4.conf   # 11
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
sudo -n sh -c 'ipset save port_guard_aws6 >> /etc/port-guard/ipset-ipv6.save'

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
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws6 src -j ACCEPT
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
grep -c '^add port_guard_aws6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^ExecStart=' /etc/systemd/system/port-guard.service.d/20-ipv6.conf   # 11
```

| 行 | 意味 |
|---|---|
| `install -d -m 755 <フォルダ>` | フォルダを作る（すでにあれば何もしない） |
| `ipset save <集合> > <ファイル>` | 集合を作る行（`create ...`）と、中身の行（`add ...`）を、`ipset restore` で読める形でファイルに書き出す。2 つ目の集合は `>>`（書き足す）で同じファイルに続ける |
| `[Service]` | ファイルの中で、ここから後がサービスの動かし方の設定であることを示す見出し |
| `ExecStart=/usr/sbin/ipset restore -exist -file <ファイル>` | 起動時に、保存した集合を読み込む（集合がなければ作り、中身を入れる）。`-exist` は、集合や中身がすでにあっても失敗にしない |
| `ExecStart=-...` の `-` | その行が失敗しても、次の行へ進む（systemd の書き方）。`-N` は「チェーンがすでにある」とき、`-D` は「`INPUT` チェーンに、`PORT_GUARD` へ飛ばすルールがまだない」ときに失敗するが、どちらも失敗してかまわないので `-` を付けている |
| `-F PORT_GUARD` | チェーンの中身を空にしてから、6 つのルールを入れ直す（何度流しても二重に入らない） |
| `-D INPUT ...` の後に `-I INPUT 1 ...` | `INPUT` チェーンから、`PORT_GUARD` へ飛ばすルールを削除してから、差し込み直す（何度流しても二重に入らない） |
| `-w 10` | ロックが空くまで最大 10 秒待つ。起動時に iptables を操作するほかのもの（Docker など）とも、取り合いで失敗しない。10 秒で空かなければ、その行で止まってサービスは `failed`（失敗）になる（`journalctl -b -u port-guard` で分かる） |
| `systemctl daemon-reload` | systemd に、置いたファイルを読み直させる |
| 確認の `head -3` | 保存したファイルの先頭 3 行（`create port_guard_jp hash:net family inet ...` と `add ...`）を表示する |
| 確認の `grep -c '^add port_guard_jp '` | 保存したファイルの中の、日本の範囲の件数。ステップ 3 の件数と同じであること |
| 確認の `grep -c '^ExecStart='` | 置いたファイルの `ExecStart=` の行数。11 であること |

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
systemctl cat port-guard | grep -c '^ExecStart='      # 11（IPv4 だけ）か 22（IPv4 と IPv6）。本体と追加の設定をまとめて表示する
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

## ステップ 7: Let's Encrypt の証明書の更新の間だけ 80 番を開ける hook を置く（certbot で証明書を更新している台だけ。`command/port_guard/07-*.sh`）

| 項目 | 内容 |
|---|---|
| なぜ要るか | Let's Encrypt は、証明書を更新するときに、**海外を含む複数の場所から** 80 番に確認の接続をしてくる（HTTP-01 の確認）。その送り元は公開されていないので、許可の一覧にも書けない。絞り込みを入れたままだと確認が捨てられ、更新が失敗し、やがて証明書が切れる |
| すること | certbot の「更新の前と後に、決めたスクリプトを動かす仕組み」（hook）に、2 つのスクリプトを置く。更新の前に、iptables のコマンドで、カーネルの `INPUT` チェーンの一番上に「TCP の 80 番は、どこからでも通す」ルールを 1 つ差し込み、更新の後に削除する |
| 開く時間・範囲 | certbot が実際に更新を試みる間（数秒〜数分）だけ。**80 番だけ**で、443 番は絞ったまま（そのため、確認のパスが HTTPS へ転送されていないことが前提。7-1 で確かめる）。更新が要る証明書がない回（期限の 30 日前より前）は、hook は動かず、何も開かない |
| 開いている間の影響 | 80 番は世界中から受け付ける。80 番でアプリを出している台（`old_app_a` など）は、その間（最大 30 分）アプリの国の絞り込みが外れる。許容するかは [確認すること](./confirmation-items.md) の L14 |
| セキュリティグループ | hook が開けるのは iptables だけ。セキュリティグループで 80 番が全世界に開いていることが前提（[確認すること](./confirmation-items.md) の L8） |
| 前提 | 証明書の更新を、cron などから **`certbot renew`** で行っていること（hook の置き場所 `/etc/letsencrypt/renewal-hooks/` が効くのは `renew` のときだけ）。7-1 で確かめる |
| 要らない台 | Let's Encrypt の証明書を certbot で更新していない台 |

開きっぱなしを防ぐ仕組み、ファイルを編集しないこと、設計の理由（cron の時刻で外す案を採らなかった理由など）、今の仕様での期限切れのリスクは、[補足](./bastion-install-supplement.md) の「A. Let's Encrypt の更新の間だけ 80 番を開ける」。

置くファイル（対象のサーバー）:

| ファイル | 中身 | いつ動くか |
|---|---|---|
| `/etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh` | 80 番を通すルールを差し込み、30 分後に削除する予約を入れる | `certbot renew` が、更新が要る証明書を見つけて、更新を始める前（1 回の実行で 1 回） |
| `/etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh` | 80 番を通すルールを削除し、30 分後の予約を取り消す | 更新を試みた後（更新が失敗した場合に動くかは certbot の説明に明記がない。動かなくても、30 分後の予約で削除される） |
| `/usr/local/sbin/port-guard-acme-close` | 80 番を通すルールを削除する（上の 2 つと、30 分後の予約から呼ばれる） | 更新の後の hook と、30 分後の予約から |

### 7-1. 前提を確かめる（`command/port_guard/07-letsencrypt-check.sh`。読み取りだけ）

```bash
#!/bin/bash
# Let's Encrypt の証明書の更新の仕方を確かめる（読み取りだけ。何も変えない）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-check"

echo "-- cron（certbot の行。renew か certonly か）"
sudo -n crontab -l 2>&1 | grep -n certbot || echo "root の crontab: certbot の行なし"
sudo -n sh -c 'grep -rn certbot /etc/cron.d/ /etc/crontab /etc/cron.daily/ 2>/dev/null' || echo "/etc/cron.d など: certbot の行なし"
echo "-- cron（ユーザーごとの crontab）"
sudo -n sh -c 'grep -Hn certbot /var/spool/cron/* 2>/dev/null' || echo "ユーザーの crontab: certbot の行なし"
echo "-- systemd のタイマー（certbot のもの）"
systemctl list-timers --all 2>/dev/null | grep -i certbot || echo "certbot のタイマー: なし"
echo "-- certbot の版"
sudo -n certbot --version 2>&1 || echo "certbot: 見つからない"
echo "-- 証明書と有効期限"
sudo -n certbot certificates 2>&1 || echo "証明書の一覧: 取れない"
echo "-- 証明書ごとの設定（確認の方式と、設定ずみの hook）"
sudo -n sh -c 'grep -H "authenticator\|webroot_path\|_hook" /etc/letsencrypt/renewal/*.conf' 2>&1 || echo "設定: なし"
echo "-- すでにある hook のファイル"
sudo -n sh -c 'ls -l /etc/letsencrypt/renewal-hooks/*/' 2>&1 || echo "hook のフォルダ: なし"
echo "-- 80 番の確認のパスが HTTPS へ転送されていないか（証明書ごと）"
for conf in $(sudo -n sh -c 'ls /etc/letsencrypt/renewal/*.conf' 2>/dev/null); do
  domain=$(basename "$conf" .conf)
  echo "--- ${domain}"
  curl -sS -o /dev/null -D - -m 5 -H "Host: ${domain}" "http://127.0.0.1/.well-known/acme-challenge/port-guard-check" 2>&1 | grep -iE '^(HTTP/|Location:|curl:)' || true
done
```

| 見ること | 期待する内容 | 違ったら |
|---|---|---|
| cron の行 | `certbot renew`（`00 04 01 * *` と `00 04 16 * *` の見込み） | `certbot certonly ...` を直接呼んでいるなら、7-2 の hook のフォルダは効かない。cron の行に `--pre-hook /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh --post-hook /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh` を足す形になる（この手順では扱わない。先に相談する） |
| ユーザーごとの crontab | root の行だけ | `centos` など別のユーザーの行があれば、`sudo` の設定と、hook が root で動くことを確かめる。cron の行に `--post-hook` があっても残す |
| 証明書と有効期限 | 残り日数に余裕がある | 更新が近い台は、ステップ 4 と 7 の間を空けない |
| certbot のタイマー | なし（cron で更新している） | systemd のタイマーで `certbot renew` を動かしていても、hook のフォルダは効くので、そのまま 7-2 へ進んでよい |
| certbot の版 | 0.19 以上（hook のフォルダ `renewal-hooks` に対応した版） | それより古ければ、hook のフォルダは効かない（先に相談する）。3.2.0 より前は、hook のフォルダが効くのは `renew` のときだけ |
| `authenticator` | `webroot`（HTTP-01 の確認。80 番に確認が来る） | `dns-...` なら、80 番に確認は来ないので、このステップは要らない |
| すでにある hook | `deploy_hook`（Apache を読み直すなど）があっても、そのまま残す | このステップが足すのは pre と post のファイルだけ |
| **確認のパスの転送** | `HTTP/1.1 404` など、`Location: https://...` が付かない（`port-guard-check` というファイルはないので、404 でよい） | `301`・`302` で `Location: https://...` が出たら、下の「80 番が HTTPS へ転送しているとき」のとおりに直す。直さないと更新が失敗する |

#### 80 番が HTTPS へ転送しているとき

Let's Encrypt の確認はリダイレクトをたどる。80 番が HTTPS へ転送していると、確認は 443 番へ進み、そこは絞ったままなので、更新が失敗する。**確認のパス（`/.well-known/acme-challenge/`）だけを、転送から外す**。Apache の 80 番の設定（`<VirtualHost *:80>`）を、今の書き方に合わせて直す。

`RewriteRule` で転送している場合（`RewriteRule` の直前に条件を 1 行足す）:

```apache
RewriteEngine On
RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
```

`Redirect` で転送している場合（`Redirect` は条件を付けられないので、`RedirectMatch` に置き換える。`www.example.com` は今の転送先に合わせる）:

```apache
RedirectMatch 301 ^/(?!\.well-known/acme-challenge/)(.*)$ https://www.example.com/$1
```

直した後に、`sudo apachectl configtest` で書き方を確かめ、`sudo apachectl graceful` で読み直す。もう一度 `07-letsencrypt-check.sh` を流して、`Location:` が出なくなったことを確かめる。Apache を変えたくない場合は、更新の間だけ 443 番も開ける形にもできるが、その間はサイト全体が開く（hook の変更が要る）。上の 2 つの例は、対象のサーバーの設定に合わせて確かめていない。

### 7-2. hook を置く（`command/port_guard/07-letsencrypt-hooks.sh`）

```bash
#!/bin/bash
# Let's Encrypt の証明書の更新の間だけ、TCP の 80 番をどこからでも通す hook を置く
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-hooks"

sudo -n install -d -m 755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post

# 80 番を通すルールを削除する（更新の後の hook と、30 分後の予約から呼ばれる。何度流してもよい）
sudo -n tee /usr/local/sbin/port-guard-acme-close > /dev/null <<'EOF'
#!/bin/bash
# port-guard: Let's Encrypt の確認のために差し込んだ「TCP の 80 番は通す」ルールを、カーネルの INPUT チェーンから削除する
# 同じ条件のルールを、削除できなくなるまで削除する（何かの理由で 2 つ入っていても残さない）
while /usr/sbin/iptables -w 10 -D INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; do :; done
while /usr/sbin/ip6tables -w 10 -D INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; do :; done
# 残っていないかを確かめて、記録に残す（journalctl -t port-guard-acme で見られる）
if /usr/sbin/iptables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; then
  /usr/bin/logger -t port-guard-acme "WARNING: tcp/80 rule (IPv4) is still in INPUT"
else
  /usr/bin/logger -t port-guard-acme "closed tcp/80"
fi
exit 0
EOF
sudo -n chmod 755 /usr/local/sbin/port-guard-acme-close

# 更新の前: 80 番を通すルールを差し込み、30 分後に削除する予約を入れる
sudo -n tee /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh > /dev/null <<'EOF'
#!/bin/bash
# port-guard: Let's Encrypt の確認の間だけ、カーネルの INPUT チェーンの一番上に「TCP の 80 番は、どこからでも通す」ルールを差し込む
# すでに差し込まれていれば、差し込まない（二重に入れない）
/usr/sbin/iptables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null \
  || /usr/sbin/iptables -w 10 -I INPUT 1 -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT
/usr/sbin/ip6tables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null \
  || /usr/sbin/ip6tables -w 10 -I INPUT 1 -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT
# 30 分後に削除する予約（前の予約が残っていれば、取り消してから入れ直す）
/usr/bin/systemctl stop port-guard-acme-close.timer 2>/dev/null
/usr/bin/systemctl reset-failed port-guard-acme-close.service 2>/dev/null
/usr/bin/systemd-run --unit=port-guard-acme-close --on-active=30min /usr/local/sbin/port-guard-acme-close
# 差し込めたかを確かめて、記録に残す（journalctl -t port-guard-acme で見られる）
if /usr/sbin/iptables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; then
  /usr/bin/logger -t port-guard-acme "opened tcp/80 for Let's Encrypt (closes after renewal, or in 30 minutes at the latest)"
else
  /usr/bin/logger -t port-guard-acme "WARNING: failed to open tcp/80 (IPv4). The renewal may fail"
fi
# 失敗しても certbot の更新は続けさせる（開けられなかったときは、確認が通らず更新が失敗するだけで、今と同じ）
exit 0
EOF
sudo -n chmod 755 /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh

# 更新の後: 80 番を通すルールを削除し、30 分後の予約を取り消す
sudo -n tee /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh > /dev/null <<'EOF'
#!/bin/bash
# port-guard: Let's Encrypt の確認が終わったので、差し込んだ 80 番のルールを削除し、30 分後の予約を取り消す
/usr/local/sbin/port-guard-acme-close
/usr/bin/systemctl stop port-guard-acme-close.timer 2>/dev/null
exit 0
EOF
sudo -n chmod 755 /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh

# 確認
sudo -n ls -l /usr/local/sbin/port-guard-acme-close /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh
sudo -n bash -n /usr/local/sbin/port-guard-acme-close
sudo -n bash -n /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh
sudo -n bash -n /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh
```

| 行 | 意味 |
|---|---|
| `install -d -m 755 .../pre .../post` | hook のフォルダを作る（すでにあれば何もしない） |
| `tee <ファイル> <<'EOF'` 〜 `EOF` と `chmod 755` | 間の中身で、対象のサーバーにスクリプトを置き、実行できるようにする（certbot は、実行できるファイルだけを hook として動かす） |
| `iptables -C INPUT <条件>` | その条件のルールが、カーネルの `INPUT` チェーンにあるかを調べる（あれば成功、なければ失敗）。`||` の後は、なかったときだけ動く |
| `iptables -I INPUT 1 -p tcp --dport 80 ... -j ACCEPT` | カーネルの `INPUT` チェーンの 1 番目に「TCP の 80 番あては通す」ルールを差し込む。`PORT_GUARD` へ飛ばすルールより上にあるので、80 番は絞り込みの前に通る。443 番は当たらないので、いつもどおり絞られる |
| `-m comment --comment port-guard-acme` | ルールに目印の文字列を付ける（動きには影響しない）。削除のときに、この目印まで一致するルールだけを削除する（ほかの 80 番のルールを誤って削除しない） |
| `iptables -D INPUT <差し込んだときと同じ条件>` | カーネルの表から、その内容のルールを探して削除する。ルールの番号や、別の管理の記録は要らない。`while ...; do :; done` は、削除できなくなるまで繰り返す |
| `ip6tables` の行 | IPv6 でも同じことをする。IPv6 を絞っていない台でも、通すルールが一時的に入るだけで害はない（Let's Encrypt は、ドメインに IPv6 のアドレスがあれば IPv6 でも確認に来る） |
| `systemd-run --unit=port-guard-acme-close --on-active=30min <コマンド>` | systemd に「30 分後に、このコマンドを 1 回だけ動かす」一時の予約を作らせる。ファイルには残らず、再起動で消える。同じ名前の予約が残っていると作れないので、その前の `systemctl stop ...timer` と `reset-failed` で片付ける |
| `logger -t port-guard-acme "..."` | システムの記録に残す。`journalctl -t port-guard-acme` で、いつ開けて、いつ閉じたかが見られる |
| `exit 0` | hook はいつも成功で終える（certbot の更新を止めない） |
| 確認の `bash -n` | 置いたスクリプトの書き方に誤りがないか（実行はしない） |

### 7-3. hook を手で動かして確かめる

置いた hook を、certbot を使わずに手で動かして、ルールが差し込まれ、削除されることを確かめる。**手で動かしている間（数秒）、80 番がどこからでも通る**。

`command/port_guard/07-letsencrypt-hooks-test.sh`:

```bash
#!/bin/bash
# 置いた hook を手で動かして、80 番を通すルールが差し込まれ、削除されることを確かめる（数秒だけ 80 番が開く）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-hooks-test"

echo "-- 更新の前の hook を動かす"
sudo -n /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh
sudo -n iptables -w 10 -S INPUT | head -3                       # 1 行目に --comment port-guard-acme のルールがあること
sudo -n systemctl list-timers --all 2>/dev/null | grep port-guard-acme-close || echo "30 分後の予約: なし"

echo "-- 更新の後の hook を動かす"
sudo -n /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh
sudo -n iptables -w 10 -S INPUT | grep -c port-guard-acme || true    # 0
sudo -n ip6tables -w 10 -S INPUT | grep -c port-guard-acme || true   # 0
sudo -n systemctl list-timers --all 2>/dev/null | grep port-guard-acme-close || echo "30 分後の予約: なし（取り消された）"
sudo -n journalctl -t port-guard-acme --no-pager 2>/dev/null | tail -2   # opened ... と closed tcp/80
```

| 確かめること | 期待する内容 |
|---|---|
| 更新の前の hook の後の `INPUT` | 1 行目が `-A INPUT -p tcp -m tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT`、2 行目が `-A INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD` |
| 30 分後の予約 | 更新の前の hook の後は `port-guard-acme-close.timer` がある。更新の後の hook の後はない |
| 更新の後の hook の後 | `port-guard-acme` の付いたルールが 0（IPv4・IPv6 とも） |
| 記録 | `opened tcp/80 ...` と `closed tcp/80` |

certbot から動くことまで確かめるには、**絞り込みが効いている 1 台で** `sudo certbot renew --dry-run` を流す（Let's Encrypt の試験用の窓口で、更新の手順だけを本物どおりに流す。証明書は変わらない。`--dry-run` でも pre と post の hook は動く）。確認が通り、`/var/log/letsencrypt/letsencrypt.log` に `port-guard-open-80.sh` と `port-guard-close-80.sh` が動いた記録があることを見る。海外からの確認まで含めて試せるので、ほかの台に広げる前に流す。

`--dry-run` の成功だけではステップ 7 の完了としない。**実際の更新が 1 回通り、`journalctl -t port-guard-acme` に `opened` と `closed` が記録され、証明書の期限が延びたことを確かめて完了とする**。確かめ方は次の 7-4。残り日数は [`cert-expiry-check.sh`](./certificate-expiry-check.md) で確かめる（[確認すること](./confirmation-items.md) の L16・L17）。

### 7-4. 実際の更新の後に確かめる（`command/port_guard/07-letsencrypt-renewal-check.sh`。読み取りだけ）

hook で 80 番を一時的に開けた結果、**実際に証明書が更新され、httpd が新しい証明書を返しているか**を、ログと証明書で確かめる。7-3 の `--dry-run` では証明書は変わらないので、ここは実際の更新の後にしか確かめられない。

| 項目 | 内容 |
|---|---|
| いつ流すか | 証明書の残り日数が 30 日を切った後の、最初の cron の実行（毎月 1 日と 16 日の 4:00 の見込み）の後。残り日数は 7-1 の `certbot certificates` か、[`cert-expiry-check.sh`](./certificate-expiry-check.md) で分かる |
| 流す順 | 対象のサーバーでこのスクリプトを流し、続けて踏み台サーバーで `cert-expiry-check.sh` を流す（[確認すること](./confirmation-items.md) の L16・L17） |
| 見るもの | cron の記録 → hook の記録 → certbot のログ → 証明書のファイル → 443 番が返す証明書の順に、どこまで進んだかを見る |

```bash
#!/bin/bash
# 実際の証明書の更新の後に、hook が 80 番を開けて閉じたか、証明書が新しくなったか、httpd が新しい証明書を返しているかを確かめる（読み取りだけ。何も変えない）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-renewal-check"

echo "-- cron の記録（certbot の行。cron が certbot を動かした時刻）"
sudo -n sh -c 'grep -H certbot /var/log/cron*' 2>/dev/null || echo "/var/log/cron: certbot の行なし"

echo "-- hook の記録（journalctl。開けた時刻と閉じた時刻）"
sudo -n journalctl -t port-guard-acme --no-pager -o short-iso 2>&1 | tail -20 || echo "journalctl: 見られない"
echo "-- hook の記録（/var/log/messages。再起動で journalctl から消えたとき用）"
sudo -n sh -c 'grep -H port-guard-acme /var/log/messages*' 2>/dev/null || echo "/var/log/messages: port-guard-acme の行なし"

# certbot certificates を流すと certbot のログが 1 つ増えるので、certbot のログは先に見る
echo "-- certbot のログ（20 日以内に書かれたもの。新しい順）"
sudo -n find /var/log/letsencrypt -type f -mtime -20 -exec ls -lt --time-style=long-iso {} + 2>&1 || echo "/var/log/letsencrypt: 見られない"
echo "-- certbot のログの中の hook の名前とエラー（20 日以内に書かれたもの）"
sudo -n find /var/log/letsencrypt -type f -mtime -20 -exec grep -Hi 'port-guard\|error' {} + 2>/dev/null | tail -40 || echo "該当の行なし"

echo "-- 証明書と有効期限（certbot certificates）"
sudo -n certbot certificates 2>&1 || echo "証明書の一覧: 取れない"

echo "-- 証明書ごとの、ファイルのリンク先・期限と、443 番が返す証明書"
for conf in $(sudo -n sh -c 'ls /etc/letsencrypt/renewal/*.conf' 2>/dev/null); do
  name=$(basename "$conf" .conf)
  echo "--- ${name}"
  sudo -n ls -l --time-style=long-iso "/etc/letsencrypt/live/${name}/" 2>&1 | grep -- '->' || true
  echo "ファイル（live/${name}/cert.pem）:"
  sudo -n openssl x509 -noout -serial -dates -in "/etc/letsencrypt/live/${name}/cert.pem" 2>&1 || true
  echo "443 番が返す証明書（127.0.0.1:443、SNI は ${name}）:"
  echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "${name}" 2>/dev/null | openssl x509 -noout -serial -dates 2>&1 || echo "443 番から取れない"
done
```

| 行 | 意味 |
|---|---|
| `grep -H certbot /var/log/cron*` | cron が certbot を動かした記録。Amazon Linux 2 では cron の記録は `/var/log/cron` に出る見込み（実環境では確かめていない）。古い記録は日付の付いたファイル（`/var/log/cron-<日付>`）に回されている見込みなので、まとめて見る |
| `journalctl -t port-guard-acme` | 7-2 の hook と `port-guard-acme-close` が `logger -t port-guard-acme` で残した記録。`-o short-iso` で年月日まで表示する |
| `grep -H port-guard-acme /var/log/messages*` | 同じ記録を、ファイルに書かれたほうから見る。再起動を挟むと `journalctl` から消える設定のことがあるため（対象のサーバーで journald が記録をファイルに残す設定かは確かめていない。`logger` の記録が `/var/log/messages` にも書かれるかも、実環境で確かめる） |
| `find /var/log/letsencrypt -type f -mtime -20` | certbot のログ。certbot は既定で `/var/log/letsencrypt` に記録を残し、ファイルが 1,000 個になると古いものから消す（`--max-log-backups`）。ディストリビューションによっては certbot のこの仕組みを止めて logrotate で回している（`/etc/logrotate.d/` を見る）。cron の実行の後にも certbot を流すと（`certbot certificates` を含む）ログが増えるので、更新の日の 4:00 ごろの時刻のファイルを探す |
| `grep -Hi 'port-guard\|error'` | certbot のログの中から、hook のファイルの名前と、エラーの行を拾う。hook を動かしたことが certbot のログに書かれるか、書かれるならどう書かれるかは、公式のドキュメントに書かれていないので、環境で確かめる |
| `certbot certificates` | 証明書ごとの `Expiry Date`（期限）と残り日数（`VALID: ... days`） |
| `ls -l /etc/letsencrypt/live/<証明書の名前>/` | `cert.pem` などのリンク先と、リンクの時刻。certbot は更新のときに `live` の下を新しいファイルに向け直す。リンク先のファイルの名前の付け方は公式のドキュメントに書かれていないので、**更新の前と変わったか**だけを見る |
| `openssl x509 -noout -serial -dates -in .../cert.pem` | ファイルの証明書のシリアル番号と期限（`notBefore`・`notAfter`） |
| `openssl s_client -connect 127.0.0.1:443 -servername <証明書の名前>` | httpd が 443 番で**実際に返している**証明書のシリアル番号と期限。ファイルのシリアル番号と比べる。証明書の名前がドメインと違う（`example.com-0001` など）と、別の証明書が返ることがある。そのときは、その証明書のドメインに読み替えて手で流す |

結果の見方（上から順に見て、最初に「失敗のとき」に当たった行が原因の場所）:

| 見ること | 成功のとき | 失敗のとき・次に見ること |
|---|---|---|
| cron の記録 | 更新の予定の日の 4:00 ごろに certbot の行がある | 行がない: cron が certbot を動かしていない（cron の行・時刻を 7-1 で見直す。L1）。この回は更新を試みていない |
| hook の記録 | 同じ日に `opened tcp/80 ...` と `closed tcp/80` が組で並び、間が数秒〜数分 | **何もない**: 更新が要る証明書がなかった（`certbot certificates` の残り日数が 30 日より多いなら正常。hook は更新が要るときだけ動く）か、hook が動いていない（cron が `certbot certonly` を直接呼んでいる、hook のファイルに実行の権限がない。7-1・7-2 を見直す）<br>**`opened` と `closed` の間がほぼ 30 分**: 更新の後の hook が動かず、30 分後の予約で閉じた。certbot が途中で止まった見込みなので、certbot のログを見る<br>**`WARNING: failed to open tcp/80 (IPv4)`**: 80 番を開けられず、確認が通らなかった見込み。`iptables -S INPUT` の状態を見る<br>**`WARNING: tcp/80 rule (IPv4) is still in INPUT`**: ルールが残っている。`sudo -n iptables -w 10 -S INPUT` で確かめ、`sudo -n /usr/local/sbin/port-guard-acme-close` で削除する |
| certbot のログ | 更新の日の 4:00 ごろのファイルに、エラーの行がない（成功のときの表示の例は、環境で確かめる） | エラーの行から原因を見る。確認の接続が届かなかった旨なら、80 番が開いていない・届いていない（hook の記録、L4 の HTTPS への転送、L5 の DNS、L8 のセキュリティグループ） |
| `certbot certificates` | `Expiry Date` が更新の前より先に延び、残り日数が 90 日の証明書なら 89 日前後 | 延びていない: 更新されていない。certbot のログを見る |
| ファイル（`live/.../cert.pem`）のリンク先と期限 | リンク先が更新の前と変わり、`notAfter` が延びている | 変わっていない: 更新されていない（上と同じ） |
| 443 番が返す証明書 | シリアル番号がファイルと同じ、`notAfter` が延びている | **ファイルは新しいのに、443 番が古い証明書を返す**: httpd が新しい証明書を読み直していない。`sudo -n apachectl graceful` で読み直し、もう一度確かめる。次回からのために、7-1 で `deploy_hook` や cron の行の `--post-hook` で httpd を読み直しているかを見る（この手順では足さない。先に相談する） |
| 踏み台サーバーの `cert-expiry-check.sh` | `OK` で、残り日数が延びている | `WARN` なら上の行を順に見る。`ERROR` なら接続を見る（[証明書の期限の確認](./certificate-expiry-check.md)） |

注意:

- `sudo certbot renew --dry-run`（7-3）でも更新の前と後の hook は動くので、`opened` と `closed` の記録が残る。cron の時刻（4:00 ごろ）のものかどうかで、実際の更新の記録と見分ける
- `certbot renew` は、更新を試みて失敗したときだけ終了コード 1 を返し、更新が要る証明書がなかったときも成功したときも 0 を返す（公式のドキュメントの説明）。cron の終了コードだけでは、更新されたかは分からない
- certbot は、webroot の方式で更新したときに httpd を読み直すとは、公式のドキュメントに書かれていない。更新の後に読み直すのは、更新が成功したときだけ動く deploy hook（`--deploy-hook`・`/etc/letsencrypt/renewal-hooks/deploy/`）などの仕組み。今の台にあるかは 7-1 の「すでにある hook」で分かる

この節の certbot の挙動（ログの置き場所と回し方、hook が動く条件、`--dry-run` と hook、終了コード、`live` の下の更新、`certbot certificates` の表示、deploy hook）は、[User Guide（Certbot）](https://eff-certbot.readthedocs.io/en/stable/using.html) と照らし合わせた（2026-11-11）。certbot のログのファイルの名前（`letsencrypt.log`）とログの中の文言、hook を動かしたことがログに書かれるか、`archive` の下のファイルの名前の付け方は、公式のドキュメントには書かれておらず、確かめていない。

### hook を取り除く（`command/port_guard/07-letsencrypt-hooks-remove.sh`）

```bash
#!/bin/bash
# Let's Encrypt の hook を取り除く（差し込まれたままの 80 番のルールがあれば、先に削除する）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-hooks-remove"

sudo -n /usr/local/sbin/port-guard-acme-close || true
sudo -n systemctl stop port-guard-acme-close.timer 2>/dev/null || true
sudo -n rm -f /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh /usr/local/sbin/port-guard-acme-close

# 確認
sudo -n sh -c 'ls /etc/letsencrypt/renewal-hooks/*/' 2>&1 | grep -c port-guard || true   # 0
```

port-guard 自体をアンインストールした（`uninstall.sh`）台でも、hook は残る。残しても、80 番を通すルールを一時的に差し込んで削除するだけで害はないが、不要なら取り除く。

## 一覧を新しくするとき（日本の範囲・AWS の範囲・許可する IP アドレス）

> **この節は、踏み台サーバーから人が流す手順**（2026-11-09 の想定。[確認すること](./confirmation-items.md) の R1・R2）。S3 に置いた一覧を各サーバーが取りに行く形は見送った（[補足](./bastion-install-supplement.md) の「B」に案だけを残している）。

APNIC の割り当ては少しずつ変わり（月に数件〜数十件）、AWS の範囲の一覧も随時更新される。月に 1 回を目安に、次の順に流す。許可する IP アドレスを変えたときも同じ手順で流す。ステップ 3 の「空にしてから入れる」と違い、**集合が空になる時間はできない**。

| 順 | どこで | すること |
|---|---|---|
| 1 | 踏み台サーバー | `bash command/make-jp-lists.sh` と `bash command/make-aws-lists.sh` で一覧を作り直す。許可する IP アドレスを変えるなら、`port_guard_whitelists/allow-ipv4.txt`（と `allow-ipv6.txt`）を書き直す（ステップ 0） |
| 2 | 踏み台サーバー | `bash command/make-refresh.sh` で、一覧を確かめて、各サーバーに送るファイルを作る |
| 3 | 1 台 | `command/port_guard/refresh-ipv4.sh`（IPv6 も絞っている台は `refresh-ipv6.sh` も）を流して、結果を確かめる |
| 4 | 残りの台 | 踏み台サーバーにある今のスクリプトで、同じファイルを流す |

実際に流すコマンド:

```bash
# 1. 踏み台サーバーのカレントのフォルダで、一覧を作り直す
bash command/make-jp-lists.sh
bash command/make-aws-lists.sh

# 2. 踏み台サーバーのカレントのフォルダで、一覧を確かめて、各サーバーに送るファイルを作る
bash command/make-refresh.sh

# 3. まず 1 台に流す（4. 残りの台には、踏み台サーバーにある今のスクリプトで、同じファイルを流す）
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/refresh-ipv4.sh >> ./output/result.txt
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/refresh-ipv6.sh >> ./output/result.txt   # IPv6 も絞っている台だけ
```

`command/make-refresh.sh`（踏み台サーバーのカレントのフォルダで `bash command/make-refresh.sh` と実行する）:

```bash
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
```

| 確かめること | 内容 |
|---|---|
| 件数の下限 | 日本 1,000 件（IPv6 は 200 件）、AWS 100 件（IPv6 は 50 件）。足りなければ、`FORCE=1` を付けても止まる |
| 前回からの増減 | 日本と AWS の一覧で、前回 `make-refresh.sh` を流したときの一覧（`port_guard_whitelists/last-refresh/`）から 5% を超えて変わっていたら止まる。内容を確かめて問題なければ、`FORCE=1 bash command/make-refresh.sh` で進める |
| 許可の一覧 | 0 件でもよく、増減の基準も当てない（件数が少ないので、1 件の変更で基準を超えてしまうため）。増減の件数は表示されるので、目で確かめる |
| 必要なファイル | `allow-ipv4.txt`・`allow-ipv6.txt` がないと止まる。IPv6 を絞らないなら、空の `allow-ipv6.txt` を置く |

作られる `command/port_guard/refresh-ipv4.sh` の中身（`add` の行は省略。2026-11-02・2026-11-06 の一覧で約 5,100 行、約 190 KB）:

```text
#!/bin/bash
# ipset の集合 port_guard_jp・port_guard_allow・port_guard_aws の中身を入れ替え、起動時に読み込むファイルに保存し直す
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') refresh-ipv4"

# 今の集合があることを確かめる（1 つでもなければ、どれも入れ替えずに止まる）
sudo -n ipset list -t port_guard_jp > /dev/null
sudo -n ipset list -t port_guard_allow > /dev/null
sudo -n ipset list -t port_guard_aws > /dev/null

# 一時の集合を作る（前回の途中で残っていれば、先に消す）
sudo -n ipset destroy port_guard_jp_new 2>/dev/null || true
sudo -n ipset create port_guard_jp_new hash:net family inet maxelem 65536
（allow・aws も同じ）

# 一時の集合に、新しい一覧を入れる
sudo -n ipset restore -exist <<'EOF'
add port_guard_jp_new 1.0.16.0/20
...
EOF

# 件数を確かめる（足りなければ、今の集合に触らずに止まる）
（日本 1,000 件・AWS 100 件以上か）

# 今の集合と一時の集合を、一瞬で入れ替える（iptables のルールには触らない）
sudo -n ipset swap port_guard_jp_new port_guard_jp
（allow・aws も同じ）

# 一時の集合（入れ替えた後は古い中身）を消す
（3 つ）

# 起動時に読み込むファイルを、別名で作ってから置き換える（途中で失敗しても、今のファイルは壊れない）
（ipset save を 3 つ書いてから mv）

# 確認
（3 つの集合の Name・Number of entries・References）
```

| 点 | 内容 |
|---|---|
| `ipset swap <一時の集合> <今の集合>` | 2 つの集合の中身を一瞬で入れ替える。iptables のルールは集合を名前で参照しているので、ルールはそのままで、新しい中身が効く |
| 途中で失敗したとき | 入れ替えの前に失敗すれば、今の集合と保存のファイルは変わらず、絞り込みは今の一覧で効き続ける。一時の集合が残っていても、どこからも参照されず、次に流すときに消える |
| 結果の見方 | `Number of entries` が `make-refresh.sh` の表示の件数と同じで、`References` が `1`（ルールから参照されている）であること |
| 永続化していない台 | 流してかまわない。保存のファイルができるだけで、起動時には使われない |
| 前の版で入れた台 | AWS の集合がないと、最初の確認で止まる。先に「前の版の手順で入れた台に、AWS の東京と大阪の許可を足す」を流す |

### 中身を入れ替えずに、起動時に読み込むファイルだけを保存し直すとき（`save-ipv4.sh`・`save-ipv6.sh`）

`refresh-ipv4.sh` は保存も行うが、集合の中身の入れ替えとセットになっている。次のように、**今の集合の中身をそのまま保存したい**ときは、保存だけのファイルを流す。

| 使う場面 | 流すもの |
|---|---|
| ステップ 3 のファイル（`03-*.sh`）を流し直して、集合の中身を入れ替えたとき | `03-*.sh` を流した後に `save-ipv4.sh` |
| 手で `ipset add`・`ipset del` をして、その中身を再起動の後も残したいとき | `save-ipv4.sh` |

1 つのファイルに 3 つの集合が入っているので、どれか 1 つだけを変えたときも、3 行とも流す（1 行目だけだと、許可する IP アドレスと AWS の範囲がファイルから消える）。

`command/port_guard/save-ipv4.sh`:

```bash
#!/bin/bash
# 集合の今の中身を、起動時に読み込むファイルに保存し直す（05-persist-ipv4.sh の ipset save の 3 行と同じ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') save-ipv4"

sudo -n sh -c 'ipset save port_guard_jp > /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_allow >> /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_aws >> /etc/port-guard/ipset-ipv4.save'

# 確認
grep -c '^add port_guard_jp ' /etc/port-guard/ipset-ipv4.save || true      # 日本の範囲の件数
grep -c '^add port_guard_allow ' /etc/port-guard/ipset-ipv4.save || true   # 許可する IP アドレスの件数
grep -c '^add port_guard_aws ' /etc/port-guard/ipset-ipv4.save || true     # AWS の東京と大阪の件数
```

`command/port_guard/save-ipv6.sh`（IPv6 も絞っている台だけ）:

```bash
#!/bin/bash
# 集合の今の中身を、起動時に読み込むファイルに保存し直す（05-persist-ipv6.sh の ipset save の 3 行と同じ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') save-ipv6"

sudo -n sh -c 'ipset save port_guard_jp6 > /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_allow6 >> /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_aws6 >> /etc/port-guard/ipset-ipv6.save'

# 確認
grep -c '^add port_guard_jp6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_allow6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_aws6 ' /etc/port-guard/ipset-ipv6.save || true
```

流し方:

```bash
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/save-ipv4.sh >> ./output/result.txt
ssh -oStrictHostKeyChecking=no -i ~/.ssh/key.pem centos@server 'bash' < ./command/port_guard/save-ipv6.sh >> ./output/result.txt   # IPv6 も絞っている台だけ
```

`save-ipv4.sh` の代わりに、`05-persist-ipv4.sh` を丸ごと流し直してもよい（保存の 3 行に加えて、起動時のコマンドの並びのファイルを同じ中身で置き直すだけ）。ステップ 6 まで流していない（永続化していない）台では、要らない。

## 前の版の手順で入れた台に、AWS の東京と大阪の許可を足す

AWS の東京と大阪の許可（ステップ 0-3 と、ipset の集合 `port_guard_aws`・`port_guard_aws6`、`PORT_GUARD` のルール）は、2026-11-06 に足した。それより前の手順で入れた台に足すときは、次の順に流す（IPv6 も絞っている台は、IPv6 の分も）。

1. 踏み台サーバーで `bash command/make-aws-lists.sh`（ステップ 0-3）と `bash command/make-ipset-files-ipv4.sh`（ステップ 3-1）で `command/port_guard/03-aws-ipv4.sh` を作る（日本と許可の一覧のファイルも作り直されるが、流すのは AWS のものだけ）
2. `02-sets-ipv4.sh` を流す（AWS の空の集合が増える。ほかの集合はすでにあるので変わらない）
3. `03-aws-ipv4.sh` を流す（AWS の集合に一覧が入る。まだ通らない）
4. `PORT_GUARD` チェーンに、AWS のルールを差し込む（ここから東京と大阪の AWS からも通る）

   ```bash
   #!/bin/bash
   # PORT_GUARD チェーンの一番上に、AWS の東京と大阪の範囲を通すルールを差し込む（すでにあれば差し込まない）
   set -euo pipefail
   sudo -n iptables -w 10 -C PORT_GUARD -m set --match-set port_guard_aws src -j ACCEPT 2>/dev/null \
     || sudo -n iptables -w 10 -I PORT_GUARD 1 -m set --match-set port_guard_aws src -j ACCEPT
   sudo -n iptables -w 10 -S PORT_GUARD
   ```

   IPv6 は `ip6tables` と `port_guard_aws6` で同じ。差し込む場所はチェーンの一番上になる（ステップ 4 で入れた並びとは違うが、どれも「通す」ルールなので、結果は同じ。次の起動からは、ステップ 5 の並びになる）
5. 永続化している台は、`05-persist-ipv4.sh` を流し直す（保存のファイルに AWS の集合が加わり、起動時のコマンドの並びに AWS のルールが加わる）。**流し直さないまま再起動すると、AWS の許可は消える**

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
| サービスの本体（`/etc/systemd/system/port-guard.service`）と、起動時のコマンドの並び（`/etc/systemd/system/port-guard.service.d/`）。カーネルの `INPUT` チェーンから `PORT_GUARD` へ飛ばすルール | `PORT_GUARD` チェーンと集合（カーネルの中。どこからも使われないので何もしない。再起動すると消える）、保存のファイル（`/etc/port-guard/`）、入れる前のルールの控え（`/var/lib/port-guard/`）、ipset のパッケージ、ステップ 7 の Let's Encrypt の hook（残しても害はない。消すならステップ 7 の `07-letsencrypt-hooks-remove.sh`） |

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
sudo -n ipset destroy port_guard_aws || true
sudo -n ipset destroy port_guard_jp6 || true
sudo -n ipset destroy port_guard_allow6 || true
sudo -n ipset destroy port_guard_aws6 || true

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

長い前置き（仕組みの説明）、運用の仕組みの設計、ステップごとの経緯や理由、手元で確かめたこと、自動化の道具との違いは [補足](./bastion-install-supplement.md)。
