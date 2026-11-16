# allow-lists — 個別許可の IP の一覧（環境ごと。正本）

日本の範囲・AWS の東京と大阪の範囲に入っていなくても、80・443 番を受け付ける送り元の一覧。**このフォルダにあるものが正本**（2026-11-16 に決めた。秘匿情報としては扱わない）。踏み台サーバーや S3 にあるものは、ここから写したもの。

## 用語

| 名前 | 指すもの |
|---|---|
| 個別許可の IP の一覧 | `allow-lists/<環境>/allow-ipv4.txt`・`allow-ipv6.txt`。人が書く。各サーバーの ipset の集合 `port_guard_allow`・`port_guard_allow6` に入る |
| 環境 | 1 つの VPC。`development`・`staging`・`production` の 3 つ（2026-11-16 に決めた）。この名前をフォルダの名前にする。S3 の公開場所 `s3://<公開バケット>/port-guard/<環境>/current/` の `<環境>` と同じ名前にする |

## 置き方

```text
allow-lists/
  <環境>/
    allow-ipv4.txt
    allow-ipv6.txt     # IPv6 を絞らない環境でも、空のファイルを置く（ないと build-rules.sh と make-refresh.sh が止まる）
```

1 行 1 件（1 列目が IP アドレスか CIDR）。`#` から後はコメント、空の行は無視される。

```text
# 稼働サーバーの VPC（command/port_guard/00-vpc-cidr.sh の結果）
10.0.0.0/16
# 海外の拠点
203.0.113.10
```

何を書くか（VPC の範囲は必ず書く、など）は、[踏み台サーバーの手順のステップ 0-2](../bastion-install-commands.md#0-2-作業者が許可する-ip-アドレスの一覧を書く)にある。

## 使われ方

| 使う場面 | 使い方 |
|---|---|
| ipset 入れ替えスクリプトを作って S3 に上げる（[ip-port-guard-rule-refresh-pipeline](../ip-port-guard-rule-refresh-pipeline/README.md)） | `build-rules.sh <環境>` が、このフォルダの `<環境>/` から作業フォルダに写して使う |
| 踏み台サーバーから SSH で入れる手順（[bastion-install-commands.md](../bastion-install-commands.md)） | 踏み台サーバーのカレントのフォルダの `port_guard_whitelists/` に、このフォルダの `<環境>/` の 2 つのファイルを写して使う |

## 今置いてあるもの（仮置き）

| 環境 | 状態（2026-11-16） |
|---|---|
| `development` | **仮置き**。`allow-ipv4.txt`・`allow-ipv6.txt` とも、コメントだけで中身は空。`build-rules.sh <環境>` を止めずに流せるようにするために置いた |
| `staging` | 同上 |
| `production` | 同上 |

**空の一覧のまま S3 に上げない**。個別許可の IP の一覧が空の ipset 入れ替えスクリプトを各サーバーで流すと、`port_guard_allow` が空になり、VPC の中から来る 80・443 番への通信も捨てられる。`build-rules.sh`・`deploy-rules.sh` は、空であることでは止まらない（`make-refresh.sh` は、個別許可の IP の一覧を 0 件でも通す）。

踏み台サーバーの `port_guard_whitelists/` に手で置いた一覧があれば、それを環境ごとに `allow-lists/<環境>/` へ写してコミットする（踏み台サーバーに今あるかどうかは、確かめていない）。
