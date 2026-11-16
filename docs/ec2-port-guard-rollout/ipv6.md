# port-guard と IPv6

> 位置付け: port-guard（80・443 番を日本と許可した IP アドレスに絞る設定）の IPv6 の扱いをまとめる。IPv4 との違い、どの手順と道具が IPv6 に対応しているか、IPv6 のテスト用のインスタンスの作り方、手元で用意できる AWS の EC2 と Lambda だけで確認できることを書く。
>
> 確かめた範囲: AWS の仕様は AWS のドキュメントと照らし合わせた（2026-11-11）。**IPv6 の手順も確認も、まだ流していない**。
>
> 作成日: 2026-11-11

## 用語

| 用語 | 指すもの |
|---|---|
| 稼働サーバー | port-guard で 80・443 番を絞る本番のサーバー（Amazon Linux 2 の Web サーバー） |
| テスト用のインスタンス | 開発用のアカウントの、本番とは別の VPC に作る、稼働サーバーに近い構成のインスタンス（[Image Builder の定義](./al2-instance/image-builder/README.md)） |
| 海外の確認の拠点 | 海外のリージョンに置く、接続元の EC2（[outside-probe.md](./outside-probe.md)）。海外のリージョンの Lambda も同じ役に使える |
| 国内の確認用の EC2 | 東京か大阪のリージョンに置く、接続元の EC2。国内のリージョンの Lambda も同じ役に使える |

## 結論

- IPv4 と IPv6 は**別々のアドレス**で、絞り込みも別々に入れる。IPv4 だけ絞っても、IPv6 の 80・443 番は絞られない。
- IPv6 を絞る必要があるのは、**稼働サーバーに IPv6 のアドレスがあり、セキュリティグループが IPv6 の 80・443 番を通している台だけ**。
- IPv6 に対応しているのは、[踏み台サーバーから入れる手順](./bastion-install-commands.md)（`-ipv6.sh`）と Let's Encrypt の hook。**Python・sh・Ruby の道具は IPv4 だけ**。
- 手元の AWS の EC2 と Lambda だけで、「海外から止まる」と、許可の一覧・VPC の範囲・AWS の範囲で「通る」ことは確かめられる。**「日本の一般の回線から通る」は確かめられない**（作業者の PC が日本の一般の回線なら、それで確かめる）。

## IPv4 と IPv6 のアドレスの違い

1 つのインスタンスが、形式の違う別々のアドレスを両方持つ。

| 項目 | IPv4 | IPv6 |
|---|---|---|
| 例 | プライベート `10.0.1.20`、パブリック `203.0.113.10` | `2001:db8:1234:1a00::10`（1 つ） |
| プライベートとパブリック | 別のアドレス。VPC の中はプライベート、インターネットからはパブリック | 同じアドレスを VPC の中からもインターネットからも使う（Amazon が用意する範囲はインターネットに公開される） |
| 停止・起動 | パブリック IP は変わる（Elastic IP なら変わらない） | 変わらない（インスタンスを終了すると解放される） |
| DNS のレコード | A | AAAA |
| 絞り込むコマンド | `iptables` | `ip6tables` |
| port-guard の集合 | `port_guard_jp`・`port_guard_allow`・`port_guard_aws` | `port_guard_jp6`・`port_guard_allow6`・`port_guard_aws6` |
| 一覧（踏み台サーバー） | `jp-ipv4.txt`・`allow-ipv4.txt`・`aws-ipv4.txt` | `jp-ipv6.txt`・`allow-ipv6.txt`・`aws-ipv6.txt` |
| 起動時のコマンドの並び | `port-guard.service.d/10-ipv4.conf` | `port-guard.service.d/20-ipv6.conf` |

## IPv6 を絞る必要がある台

次の 2 つがそろう台だけ。どちらかがなければ、IPv6 で 80・443 番に届く経路がないので、IPv6 の分は流さない（[確認すること](./confirmation-items.md) の G4）。

| 条件 | 確かめ方 |
|---|---|
| 稼働サーバーに IPv6 のアドレスがある | `aws ec2 describe-instances --instance-ids <ID> --query 'Reservations[].Instances[].Ipv6Address' --output text` |
| セキュリティグループが IPv6 の 80・443 番を通している | `aws ec2 describe-security-groups --group-ids <ID> --query 'SecurityGroups[].IpPermissions[].[FromPort,ToPort,Ipv6Ranges[].CidrIpv6]'` |

## 今の稼働サーバーが IPv6 の要求を受け付けているかの確かめ方

稼働サーバーが IPv6 の要求を受け付けるのは、次の**経路の条件がすべてそろうとき**だけである。1 つでも欠けていれば、IPv6 では届かない。利用者がドメイン名で IPv6 を使うには、さらに DNS の AAAA レコードが要る。どれも読み取りだけで、何も変えない。

| # | 条件 | 確かめる場所 | 欠けていると |
|---|---|---|---|
| 1 | サブネットに IPv6 の範囲がある | AWS | インスタンスに IPv6 のアドレスを付けられない |
| 2 | インスタンスに IPv6 のアドレスがある | AWS | IPv6 では届かない（ここで「受け付けない」と分かる） |
| 3 | サブネットのルートテーブルに `::/0` → インターネットゲートウェイがある | AWS | インターネットから IPv6 では届かない |
| 4 | セキュリティグループが IPv6 の 80・443 番を通している | AWS | IPv6 の要求はセキュリティグループで止まる |
| 5 | ネットワーク ACL が IPv6 を通している | AWS | 独自のネットワーク ACL で IPv6 の規則がなければ止まる |
| 6 | OS に IPv6 のアドレスがあり、httpd が IPv6 で待ち受けている | 稼働サーバー | IPv6 では応答しない |
| 7 | ドメイン名に AAAA レコードがある | DNS | アドレスを直接指定すれば届くが、利用者はドメイン名では IPv6 を使わない |

### AWS の側（作業者の PC の AWS CLI）

```bash
ID=<インスタンスの ID>

# 1・2: サブネットの IPv6 の範囲と、インスタンスの IPv6 のアドレス
SUBNET=$(aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[0].Instances[0].SubnetId' --output text)
aws ec2 describe-subnets --subnet-ids "$SUBNET" --query 'Subnets[].Ipv6CidrBlockAssociationSet[].Ipv6CidrBlock' --output text
aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[].Instances[].NetworkInterfaces[].Ipv6Addresses[].Ipv6Address' --output text

# 3: ルートテーブルの ::/0（何も出なければ、サブネットはメインのルートテーブルを使っているので、そちらを見る）
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET" \
  --query 'RouteTables[].Routes[?DestinationIpv6CidrBlock==`::/0`].[DestinationIpv6CidrBlock,GatewayId]' --output text

# 4: セキュリティグループの IPv6 の受信の規則
for SG in $(aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text); do
  aws ec2 describe-security-groups --group-ids "$SG" --query 'SecurityGroups[].IpPermissions[].[FromPort,ToPort,Ipv6Ranges[].CidrIpv6]' --output text
done

# 5: ネットワーク ACL の IPv6 の規則
aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SUBNET" \
  --query 'NetworkAcls[].Entries[?Ipv6CidrBlock!=`null`].[Egress,RuleNumber,RuleAction,Ipv6CidrBlock,PortRange.From,PortRange.To]' --output text
```

### 稼働サーバーの側（踏み台サーバーから SSH）

```bash
ip -6 addr show scope global                       # 6: OS の IPv6 のアドレス（何も出なければ IPv6 のアドレスがない）
sudo ss -ltnp | grep -E ':(80|443) '               # 6: httpd の待ち受け。*:80・[::]:80 なら IPv6 でも待ち受けている。0.0.0.0:80 だけなら IPv4 だけ
grep -hE '^[[:space:]]*Listen' /etc/httpd/conf/httpd.conf /etc/httpd/conf.d/*.conf   # httpd の待ち受けの設定
sudo awk '$1 ~ /:/' /var/log/httpd/access*log* 2>/dev/null | head -5   # 実際に IPv6 の利用者から来た記録（送り元に : が入る）
```

### DNS と、実際の接続

```bash
dig +short AAAA <ドメイン>                          # 7: 何も出なければ、利用者はドメイン名では IPv6 を使わない
curl -6 -s -o /dev/null -w '%{http_code}\n' https://<ドメイン>/                # IPv6 が使える端末から。ドメイン名で IPv6 の経路を通す
curl -g -6 -s -o /dev/null -w '%{http_code}\n' 'http://[<IPv6 のアドレス>]/'   # AAAA がなくても、アドレスを直接指定して確かめる
```

### 判断

| 結果 | 意味 | port-guard の IPv6 の分 |
|---|---|---|
| 2 で IPv6 のアドレスがない | IPv6 の要求は受け付けていない | 要らない |
| 2〜6 がそろっている | IPv6 の要求を受け付けられる（AAAA がなくても、アドレスを知っている相手からは届く） | **要る** |
| 2 はあるが、3・4・5 のどれかで止まる | 経路の上では受け付けない | 要らない。ただし、後でルートやセキュリティグループを変えると届くようになるので、そのときに入れる |
| アクセスログに IPv6 の送り元がある | 実際に IPv6 で使われている | **要る**。止めると困る相手がいないかも見る |

## IPv6 に対応している手順と道具

| 手順・道具 | IPv6 | 内容 |
|---|---|---|
| [踏み台サーバーから入れる手順](./bastion-install-commands.md) | **対応** | ステップ 2〜5 の `-ipv6.sh`、`command/make-ipset-files-ipv6.sh`、`refresh-ipv6.sh`、`save-ipv6.sh`。ステップ 0・1・6 は IPv4 と共通 |
| Let's Encrypt の hook（ステップ 7） | **対応** | 更新の間、`iptables` と `ip6tables` の両方で 80 番を開ける（Let's Encrypt は AAAA があれば IPv6 でも確認に来る） |
| Python・sh・Ruby の道具（`py/`・`sh/`・`rb/`・`remote/`） | **非対応** | IPv4 だけ（[仕組み](./iptables-ipset.md)）。IPv6 を絞る台は、踏み台サーバーから入れる手順を使う |

IPv6 の許可の一覧（`allow-ipv6.txt`）には、`00-vpc-cidr.sh` で表示される VPC の IPv6 の範囲を書く。IPv6 を絞らない台でも、一覧の更新（`make-refresh.sh`）のために空の `allow-ipv6.txt` を置く。

## IPv6 のテスト用のインスタンスを作る

手順とコマンドは [Image Builder の定義の README](./al2-instance/image-builder/README.md#ipv6-も試すとき) にある。流れは次のとおり。

| # | 作業 | 内容 |
|---|---|---|
| 1 | VPC とサブネットに IPv6 を付ける（一度だけ） | VPC に Amazon が用意する `/56`、公開のサブネットに `/64`。ルートテーブルに `::/0` → インターネットゲートウェイ |
| 2 | セキュリティグループに IPv6 の受信を足す | 80・443 番の `::/0` |
| 3 | IPv6 アドレス付きで起動する | `run-instances` に `--ipv6-address-count 1`。今の版の Amazon Linux 2 の AMI なら、OS の側の設定は要らない |
| 4 | 確かめる | `ip -6 addr show eth0`、IPv6 で `/health` に `curl` |

海外の確認の拠点と国内の確認用の EC2 も、IPv6 で確かめるなら、それぞれのリージョンの VPC に同じく IPv6 を付けて、IPv6 アドレス付きで起動する。

## 手元の AWS だけで確認できること

使えるのは、海外のリージョンと国内のリージョンの、AWS の EC2 と Lambda だけとする。

**注意: 国内のリージョンの AWS から通ることは、日本の範囲の一覧が効いている証明にはならない**。port-guard は AWS の東京と大阪の範囲を丸ごと許可しているので（[確認すること](./confirmation-items.md) の G5）、国内のリージョンの EC2 と Lambda は、日本の範囲（APNIC）ではなく、AWS の範囲の集合で通る。

| 確認したいこと | 使うもの | 確かめ方 | IPv6 |
|---|---|---|---|
| 海外から止まる | 海外の確認の拠点（EC2 か Lambda） | `curl` が時間切れになる。テスト用のインスタンスの `journalctl -k` に `port-guard drop:` と送り元が記録される | IPv6 を付けた拠点の EC2 で同じ |
| AWS の東京・大阪の集合で通る | 国内の確認用の EC2 か Lambda | `curl` が応答する。`iptables -L PORT_GUARD -v -n` で、`port_guard_aws` のルールの件数が増える | IPv6 を付けた EC2 で、`ip6tables -L PORT_GUARD -v -n` の `port_guard_aws6` |
| 許可の一覧が効く | 海外の確認の拠点の EC2 | その IP を許可の一覧に入れると通り、外すと止まる | `allow-ipv6.txt` で同じ |
| VPC の範囲の許可が効く | 同じ VPC の別の EC2 | VPC の中のアドレスから通る | VPC の IPv6 の範囲で同じ |
| 日本の範囲の一覧の中身 | テスト用のインスタンスの中だけ | `ipset test port_guard_jp <日本の IP>` が `is in set`、海外の IP は入っていない | `port_guard_jp6` で同じ |
| 日本の範囲のルールの動き | 海外の確認の拠点の EC2 | その IP を一時的に `port_guard_jp` に `ipset add` すると通る（一覧の中身ではなく、ルールの仕組みの確認） | `port_guard_jp6` で同じ |
| 一覧の入れ替えで止まらない | 国内の確認用の EC2 | `refresh-ipv4.sh` を流している間も、`curl` を繰り返して途切れない | `refresh-ipv6.sh` で同じ |
| 再起動の後に戻る | テスト用のインスタンス | 再起動して、上の確認を繰り返す | `20-ipv6.conf` があること |
| hook で 80 番だけ開く | 海外の確認の拠点の EC2 | 7-3 で手動で開けている間は 80 番が通り、443 番は止まったまま | IPv6 でも同じ（hook は IPv4・IPv6 の両方を開ける） |

| 使い分け | 内容 |
|---|---|
| EC2 と Lambda | VPC の外の Lambda は、送り元の IP が決まっていない。「止まる・通る」の確認には使えるが、IP を許可の一覧に入れる確認は、IP が固定の EC2 で行う |
| IPv6 の確認 | Lambda から IPv6 で接続できるかは確かめていない。IPv6 の確認は EC2 で行う |
| 海外の拠点のリージョン | 米国のリージョンを使う。アジアのリージョンは APNIC の管理の範囲なので避ける（[outside-probe.md](./outside-probe.md)） |

## 確認できないこと

| 確認したいこと | 理由 | 代わりの方法 |
|---|---|---|
| 日本の一般の回線から通る | AWS 以外の日本の IP がない | 作業者の PC が日本の一般の回線なら、そこから `curl` するのが本物の確認になる。ほかは上の `ipset test` まで |
| 日本の IPv6 の回線から通る | 同上 | 作業者の回線が IPv6 に対応していれば確認できる |
| 実際の API の呼び出し元が止まらない | 実際の相手が分からない | [API のアクセス元の洗い出し](../api-access-sources/design.md) |
| Let's Encrypt の更新（`--dry-run`） | テスト用のインスタンスに、DNS で向いたドメイン名が要る | 開発用のドメインのサブドメインを、テスト用のインスタンスへ向けられれば確認できる（海外からの確認も含む）。IPv6 も確かめるなら AAAA も向ける |

## 確認の順番

1. テスト用のインスタンス、海外の確認の拠点、国内の確認用の EC2 を、IPv4 と IPv6 の両方のアドレス付きで作る
2. 絞り込みの前に、拠点と国内の EC2 から、IPv4 と IPv6 の両方で 80・443 番に届くことを確かめる
3. 踏み台サーバーから入れる手順を、IPv4 と IPv6 の両方で流す（ステップ 0〜4）
4. 上の「確認できること」の表を、IPv4 と IPv6 で順に確かめる
5. ステップ 5〜7 を流し、再起動と hook を確かめる

## 参考

AWS のドキュメントと照らし合わせた（2026-11-11）。

- [Add IPv6 support for your VPC](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-migrate-ipv6-add.html)
- [Manage the IPv6 addresses for your EC2 instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/working-with-ipv6-addresses.html)
- [Amazon EC2 instance IP addressing（IPv6 アドレスの扱い）](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-instance-addressing.html)
