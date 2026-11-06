# サンプル: AWS の東京・大阪のリージョンの範囲の一覧（ip-ranges.json、2026-11-06）

[踏み台サーバーから入れるコマンド](../../bastion-install-commands.md) のステップ 0-3（`make-aws-lists.sh`）の手順を確かめるときに、Python で作った一覧を、そのまま残したもの。踏み台サーバーの `make-aws-lists.sh`（`awk` で作る）の結果と、中身が 1 文字も違わないことを確かめた（`cmp`）。

**これはサンプル**。対象のサーバーに入れる一覧は、作業のときに踏み台サーバーで取り直す（AWS はこの一覧を随時更新する）。手順の検証や、取り直した一覧と比べて大きく変わっていないかを見るのに使う。

| ファイル | 内容 | 件数 | 大きさ |
|---|---|---|---|
| `aws-ipv4.txt` | AWS の東京・大阪の IPv4 の範囲（TSV）。ipset の集合 `port_guard_aws`（`family inet`）に入れるもの | 305 | 16,076 バイト |
| `aws-ipv6.txt` | AWS の東京・大阪の IPv6 の範囲（TSV）。ipset の集合 `port_guard_aws6`（`family inet6`）に入れるもの | 149 | 8,677 バイト |
| `make_aws_lists.py` | 一覧を作った Python の処理（標準のライブラリの `json`・`ipaddress` だけ） | — | — |

## ファイルの形（TSV）

```
# source: AWS ip-ranges.json createDate 2026-11-06-01-07-05
# cidr	region	service	network_border_group
66.36.6.0/24	ap-northeast-1	AMAZON	ap-northeast-1
```

| 列 | 中身 |
|---|---|
| 1 列目 | 範囲（CIDR）。ipset に入れるのはこの列だけ |
| 2 列目以降（情報） | リージョン（`ap-northeast-1`・`ap-northeast-3`）、サービス（`AMAZON`）、`network_border_group`（ネットワークの区画） |
| `#` で始まる行 | コメント（元の版と、列の名前） |

並びは `ip-ranges.json` に載っている順（並べ替えていない）。

## 取り出した条件

`make-aws-lists.sh` と同じ。

| 条件 | 値 |
|---|---|
| リージョン | `ap-northeast-1`（東京）、`ap-northeast-3`（大阪） |
| サービス | `AMAZON`（AWS の全部のサービスを含む区分。東京・大阪の個別のサービスの範囲は、IPv4・IPv6 とも、すべて `AMAZON` の範囲に含まれることを確かめた） |
| 除いたもの | `network_border_group` が `ap-northeast-1-tpe-1`（東京リージョンに属する台北のローカルゾーン。台湾にある）。この版では IPv4 の 2 件（`15.220.80.0/20`・`15.220.56.0/21`）、IPv6 は 0 件 |

| `network_border_group` | IPv4 | IPv6 | 場所 |
|---|---|---|---|
| `ap-northeast-1` | 227 | 90 | 東京 |
| `ap-northeast-3` | 78 | 53 | 大阪 |
| `ap-northeast-1-wl1-nrt-wlz-1` | 0 | 3 | Wavelength（通信事業者の網の中の区画）の東京（成田） |
| `ap-northeast-1-wl1-kix-wlz-1` | 0 | 3 | Wavelength の大阪（関西） |

## 元のデータ

| 項目 | 内容 |
|---|---|
| 出どころ | AWS の IP アドレスの範囲の一覧 `https://ip-ranges.amazonaws.com/ip-ranges.json` |
| 版 | `createDate` が `2026-11-06-01-07-05`、`syncToken` が `1793927225` |
| 取得した日 | 2026-11-06 |
| SHA-256 | `757be4d1dd1ea83da5fe3b5e919d22ad598f3cc71295c512139df6c4cd2176f7`（元のデータは約 2.7 MB あるので、ここには置いていない） |

| ファイル | SHA-256 |
|---|---|
| `aws-ipv4.txt` | `c4c68401e05ab2f146cabe0e5777d792e025be6b67bf3c8b0a17ac23543b8eab` |
| `aws-ipv6.txt` | `5dbb90b49c0b173d020932814e7a658b89489106e0b3c074e3c11fe2eb36314f` |

## 作り直し方

```bash
curl -fsS -o ip-ranges.json https://ip-ranges.amazonaws.com/ip-ranges.json
python3 make_aws_lists.py ip-ranges.json aws-ipv4.txt aws-ipv6.txt
```

同じ版（`createDate`）なら、同じ一覧になる。版が違えば、件数や中身が変わる。

## 確かめたこと

| 確かめたこと | 結果 |
|---|---|
| 踏み台サーバーの `awk` の処理（ステップ 0-3）との一致 | IPv4・IPv6 とも、情報の列とコメントの行を含めて中身が同じ（2026-11-06） |
| 範囲が正しい CIDR として読めるか | 全件読める（`ipaddress.ip_network(..., strict=True)`） |
| 入るはずの IP・入らないはずの IP | `15.152.0.1`（大阪）は入る。`15.220.80.1`（台北のローカルゾーン）と `8.8.8.8` は入らない |
| CIDR の長さの種類 | IPv4 は 20 種類、IPv6 は 10 種類 |

## 参考（AWS のドキュメント）

- [AWS IP address ranges](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ip-ranges.html)（`ip-ranges.json` の取得。ローカルゾーンは親のリージョンと同じ場所にあるとは限らず、実際の場所は `geo-ip-feed.csv` に反映される）
- [Available Local Zones](https://docs.aws.amazon.com/local-zones/latest/ug/available-local-zones.html)（`ap-northeast-1-tpe-1` は Taiwan (Taipei)、親のリージョンは `ap-northeast-1`、場所は台湾。2026-11-06 に確かめた）
