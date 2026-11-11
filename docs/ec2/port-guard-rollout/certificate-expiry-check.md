# Let's Encrypt の証明書の期限を確認する

> 位置付け: 稼働サーバーの Let's Encrypt の証明書の残り日数を、必要なときに確認する仕組み。定期の監視や通知は含めない。[確認すること](./confirmation-items.md) の L16 に対応する。
>
> 確かめた範囲: スクリプトは書き方の確認（`bash -n`）だけで、**実環境でもコンテナでも動かしていない**。Let's Encrypt と certbot の仕様は、公式のドキュメントと照らし合わせた（2026-11-10）。
>
> 作成日: 2026-11-10

## 用語

| 用語 | 指すもの |
|---|---|
| 稼働サーバー | Let's Encrypt の証明書を httpd に置いている、本番のサーバー |
| 踏み台サーバー | 稼働サーバーと同じ VPC にあり、作業者が port-guard などのコマンドを流しているサーバー |
| 残り日数 | 証明書の `notAfter` までの日数 |

## 仕組み

踏み台サーバーから各稼働サーバーの 443 番へ TLS で接続し、**実際に返ってくる証明書**の残り日数を表示する。読み取りだけで、稼働サーバーには何も置かない。

証明書のファイルではなく返ってくる証明書を見るので、更新は成功したのに httpd が読み直していない場合も分かる。Let's Encrypt の期限切れの通知メールは 2025-06-04 に終了しているので、残り日数は自分で確かめる必要がある。

スクリプトは [`command/cert-expiry-check.sh`](./command/cert-expiry-check.sh)。

## 使い方

一覧のファイルを用意する。証明書のドメインごとに 1 行で、接続先のアドレスを省略すると DNS の名前で接続する。

```text
# ドメイン 接続先のアドレス
app.example.com 10.0.1.20
```

```bash
bash command/cert-expiry-check.sh cert-targets.txt       # しきい値は既定の 14 日
bash command/cert-expiry-check.sh cert-targets.txt 30    # しきい値を 30 日にする
```

```text
RESULT  DAYS  DOMAIN                               ADDRESS          NOT_AFTER
OK        62  app.example.com                      10.0.1.20        Jan 11 04:00:00 2027 GMT
```

| 結果 | 意味 | 行うこと |
|---|---|---|
| `OK` | 残り日数がしきい値以上 | なし |
| `WARN` | 残り日数がしきい値未満 | `07-letsencrypt-check.sh` と `/var/log/letsencrypt/letsencrypt.log` で更新の状態を見る |
| `ERROR` | 証明書を取得できない | 接続先のアドレス、セキュリティグループ、httpd を確かめる |

終了コードは、すべて `OK` なら 0、`WARN` か `ERROR` があれば 1 である。

## いつ流すか

| 時点 | 目的 |
|---|---|
| ステップ 4 で絞り込みを入れる前 | 更新が近い台を把握する（[確認すること](./confirmation-items.md) の L10） |
| 証明書の更新の時期の後 | 更新が通ったかを確かめる（L17） |
| 気になったとき | いつでも流してよい |

## しきい値の 14 日

`certbot renew` は、4.0.0 より前は残り 30 日で、4.0.0 以降は有効期間の残り 1/3（90 日の証明書なら 30 日）で更新の対象にする。今の cron は毎月 1 日と 16 日の見込みで、間隔は最大で約 16 日なので、正常でも残り約 14 日までは更新されないことがある。残り 14 日未満なら、更新の機会を逃しているか、失敗している。

cron の時刻は実環境で未確認である（L1）。cron の頻度を変えたときは、しきい値も見直す。

## 定期に流す仕組み

定期に流すトリガー（cron など）と通知は、別途検討する。このスクリプトは、問題があると終了コード 1 を返すので、トリガーを足すときはスクリプトを変えずに使える。

## 前提と注意

| 項目 | 内容 |
|---|---|
| 踏み台サーバーから 443 番へ接続できること | port-guard の許可の一覧に VPC の範囲が入っていること。CloudFront を前に置いてセキュリティグループを絞るときは、踏み台サーバーからの 443 番の許可を残す |
| 実行に要るもの | 踏み台サーバーの `openssl`、`timeout`、GNU の `date` |
| 見ていないこと | 証明書のドメインと接続先の一致。一覧の接続先が違うと、別の台の証明書を表示する |

## 参考

公式のドキュメントと照らし合わせた（2026-11-10）。

- [Ending Support for Expiration Notification Emails（Let's Encrypt）](https://letsencrypt.org/2025/01/22/ending-expiration-emails/)
- [User Guide（Certbot。更新の時期）](https://eff-certbot.readthedocs.io/en/stable/using.html)
