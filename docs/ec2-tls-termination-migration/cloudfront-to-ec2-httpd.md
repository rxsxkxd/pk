# CloudFront → EC2 のときに httpd で行う設定

> 位置付け: 参考。採用した B. CloudFront → EC2 で、稼働サーバー（オリジンの EC2）の httpd（Apache 2.4）で行う設定の下書き。いつ入れるかは、[準備](./step0-preparation.md#3-稼働サーバーの-httpd-の設定)（秘密のヘッダーの確認以外）と [ステップ 3 の片付け](./step3-dns-switch.md#3-5-片付け)（秘密のヘッダーの確認）。
>
> 前提: CloudFront の Origin protocol は **HTTPS only**、オリジンリクエストポリシーは **`AllViewer`**（利用者の Host をそのまま渡す）。
>
> 確かめた範囲: AWS の仕様は AWS のドキュメント、`mod_remoteip` は Apache のドキュメントと照らし合わせた（2026-11-09）。httpd の設定は、今の構成に近いコンテナで確かめた（2026-11-10。下の「検証の結果」）。**実際の CloudFront では試していない**。
>
> 作成日: 2026-11-09

## 設定の一覧

| # | 設定 | 入れるか（いつ） | 理由 |
|---|---|---|---|
| 1 | SSL/TLS の設定を残す | 必須 | CloudFront はオリジンの証明書を検証する。自己署名の証明書は使えない |
| 2 | `ServerName` を利用者のドメインにする | 必須 | `AllViewer` で利用者の Host が届く |
| 3 | 秘密のヘッダーの確認 | **入れる**（ステップ 3 の片付け） | プレフィックスリストは CloudFront 全体の範囲で、**他人のディストリビューションからも届く** |
| 4 | 利用者の IP の復元 | **入れる**（準備） | 何もしないと、送り元がすべて CloudFront になる |
| 5 | `KeepAliveTimeout` | **入れる**（準備） | 再利用の競合による 502 を避ける |
| 6 | `old_app_a` を 443 番へ移す | **必須**（[README の T3](./README.md#決めたこと)） | CloudFront は 443 番にだけ接続するため |
| 7 | 証明書の更新の経路 | **入れる**（準備。確認のパスの設定） | 今の HTTP-01 の経路が変わる |

## 設定の全体

```apache
<VirtualHost *:443>
   ServerName <ドメイン>
   DocumentRoot /var/www/html/new_app_b
   <Directory /var/www/html>
     Options -MultiViews
     Require all granted
   </Directory>
   PassengerAppRoot /home/ruby/new_app_b
   RailsEnv <今の値>

   # 1. SSL/TLS は残す。中間証明書まで返すこと
   SSLEngine on
   SSLCertificateFile /etc/letsencrypt/live/c/cert.pem
   SSLCertificateKeyFile /etc/letsencrypt/live/c/privkey.pem
   SSLCertificateChainFile /etc/letsencrypt/live/c/chain.pem

   # 3. 秘密のヘッダーの確認
   Include /etc/httpd/secret/cloudfront-origin-verify.conf
   RequestHeader unset X-Origin-Verify

   # 4. 利用者の IP の復元
   RemoteIPHeader X-Forwarded-For
   Include /etc/httpd/cloudfront-origin-facing.conf
   RequestHeader unset X-Forwarded-For
   RequestHeader unset Client-IP

   # 5. CloudFront の Keep-alive timeout（既定 5 秒）より長くする
   KeepAlive On
   KeepAliveTimeout 10

   ErrorLog /var/log/httpd/error.log
   CustomLog /var/log/httpd/access.log combined_client_ip
</VirtualHost>
```

## 1. SSL/TLS の設定を残す

| 条件 | 内容 |
|---|---|
| 発行元 | Mozilla の一覧に入っている CA。Let's Encrypt はこのまま使える前提 |
| 名前 | `AllViewer` で Host を渡すので、**利用者のドメインの証明書**が要る。今の証明書をそのまま使える |
| 中間証明書 | 全部返すこと。足りない、順序が違う、期限切れは接続を切られて 502 になる |

`SSLCertificateChainFile` は今の形のままで動く見込みである。Apache 2.4.8 以降は、`SSLCertificateFile` に `fullchain.pem` を指定する形が勧められている（AL2023 で作り直すときに変える）。

## 2. `ServerName`

`ServerName` を利用者のドメインにする。オリジンの名前（`origin.app.example.com`）では受けない。

Host を渡さない構成（`AllViewer` を使わない）にすると、Rails がリダイレクト先などにオリジンの名前を使い、利用者が CloudFront を通らなくなる。そのため `AllViewer` を前提にしている。

## 3. 秘密のヘッダーを確認する

CloudFront の Add custom header に設定した値を、httpd で確認する。値は root だけが読めるファイルに分ける。

`/etc/httpd/secret/cloudfront-origin-verify.conf`（`chmod 600`）:

```apache
<Location "/">
   Require expr "req('X-Origin-Verify') == '<長いランダムな値>'"
</Location>
```

| 注意 | 内容 |
|---|---|
| AMI | このファイルは AMI に入る。AMI の共有の範囲に注意する |
| 値の入れ替え | CloudFront と httpd で両方の値を受ける期間を作ってから入れ替える |
| 順番 | DNS の切り替えが行き渡ってから有効にする（[ステップ 3 の片付け](./step3-dns-switch.md#3-5-片付け)）。先に入れると、まだ EC2 へ直接来ている利用者が 403 になる |

## 4. 利用者の IP を復元する

CloudFront は `X-Forwarded-For` の**末尾**に利用者の IP を足す。`mod_remoteip` は右から順に処理して、信頼できないアドレスで止まるので、直前の中継（CloudFront の接続元）を信頼すれば、利用者の IP が残る。

信頼する範囲のファイルを作る。`conf.d` の外に置いて、VirtualHost の中から `Include` で読み込む。

```bash
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json \
  | jq -r '.prefixes[] | select(.service=="CLOUDFRONT_ORIGIN_FACING") | "RemoteIPTrustedProxy " + .ip_prefix' \
  | sudo tee /etc/httpd/cloudfront-origin-facing.conf
```

`RemoteIPTrustedProxyList` でファイルを読む形にしないのは、`RemoteIPInternalProxy` と同じ VirtualHost で使うと、ヘッダーの中の CloudFront のアドレスが信頼されなかったためである（Apache 2.4.56 のコンテナで確かめた。CloudFront → ALB → EC2 で問題になる）。原因は確かめていない。CloudFront → EC2 だけなら `RemoteIPTrustedProxyList` でも動いたが、書き方をそろえるために `RemoteIPTrustedProxy` の行にしている。

| 注意 | 内容 |
|---|---|
| 範囲の更新 | 範囲は変わる。定期的に更新して `apachectl graceful` する。更新が遅れた場合、新しいアドレスからの要求はログの送り元が CloudFront のままになる |
| `RequestHeader unset` | 利用者が偽って付けた `X-Forwarded-For` の残りが Rails に渡ると、Rails 4.2 の `request.remote_ip` がそちらを選ぶことがある。`Client-IP` も同じ |
| ログ | `%a` を使う形式（オプションの [alb-to-ec2.md](./options/alb-to-ec2.md#3-httpd-に-http-の-virtualhost-を足す) の `combined_client_ip`）で利用者の IP が出る。Apache 2.4.56 のコンテナでは、`combined`（`%h`）でも利用者の IP が出た |
| アプリ側で行う場合 | [`trusted_proxies` の案](../notes/ec2-operations/access-restriction-alb-cloudfront.md#そのほかに変わること)もある。httpd で復元する方が、ログとアプリの両方に効く |

## 5. `KeepAliveTimeout`

CloudFront の Keep-alive timeout（既定 5 秒）より長くする。短いと、CloudFront が再利用しようとした接続を httpd が閉じて、エラーになることがある。Keep-alive timeout を延ばしたときは、こちらも合わせて延ばす。

## 6. `old_app_a` を 443 番へ移す

CloudFront が HTTPS Only で接続すると、今の `*:80` の `old_app_a` には届かない。`*:443` の VirtualHost の中に足す。`Alias` のパスは実際の配置に合わせる。

```apache
Alias /old_app_a /home/ruby/old_app_a/public
<Location /old_app_a>
   PassengerBaseURI /old_app_a
   PassengerAppRoot /home/ruby/old_app_a
</Location>
<Directory /home/ruby/old_app_a/public>
   Options -MultiViews
   Require all granted
</Directory>
```

`old_app_a` を平文のまま残す必要があるなら、CloudFront に HTTP only のオリジンを足し、`/old_app_a*` のビヘイビアで振り分ける方法もある。ただし、CloudFront から EC2 までインターネットを平文で通る。

## 証明書の更新

今の更新は HTTP-01（80 番の `/.well-known/acme-challenge`）である。切り替えの後は、Let's Encrypt からの確認が CloudFront を通るようになり、セキュリティグループで 80 番を閉じると直接も届かなくなる。

| 方法 | 内容 | 注意 |
|---|---|---|
| **A. HTTP-01 を CloudFront 経由で続ける（採用。2026-11-11）** | 下の設定を 443 番の VirtualHost に足す | 地理的制限を使うと、海外からの確認が止まる。WAF でこのパスを例外にする（`step2-waf.yml`） |
| B. DNS-01（見送り） | CloudFront と無関係に更新できる | DNS の API の権限の持たせ方。[Let's Encrypt の自動化](../notes/ec2-operations/letsencrypt-automation.md) |
| C. ACM の ACME 証明書またはエクスポートできる証明書（見送り） | EC2 で使える公開の証明書 | エクスポートできる証明書は有料で、有効期間は 198 日。配置は自分で行う。この用途で使えるかは試していない |

A の設定:

```apache
Alias /.well-known/acme-challenge /var/www/html/.well-known/acme-challenge
<Directory /var/www/html/.well-known/acme-challenge>
   PassengerEnabled off
   Require all granted
</Directory>
```

利用者向けの HTTP は CloudFront が HTTPS へリダイレクトし、Let's Encrypt はリダイレクトをたどる見込みである。切り替えの後に `sudo certbot renew --dry-run` で確かめる。

## 設定を変えなくてよいこと

| 項目 | 理由 |
|---|---|
| `X-Forwarded-Proto` の設定 | HTTPS で受けるので、Rails は `HTTPS=on` で HTTPS と認識する |
| HTTP/2（`mod_http2`） | CloudFront からオリジンへは HTTP/1.1 で接続する。利用者との HTTP/2 は CloudFront が受ける。httpd の設定は残しても害はない |

**Origin protocol を HTTP only にする場合**（採らない）は、CloudFront が `X-Forwarded-Proto` を取り除くので、Rails が HTTP と誤認する。`force_ssl` が有効なら無限にリダイレクトする。`RequestHeader set X-Forwarded-Proto "https"` が要る。

## 検証の結果

今の構成に近いコンテナ（Amazon Linux 2、Apache 2.4.56、Passenger 6.0.18、Rails 4.2、rack 1.6.13）に上の設定を入れ、別のコンテナから CloudFront を模した要求を送って確かめた（2026-11-10）。コンテナの証明書は自己署名で、接続時に検証していない。

| 項目 | 結果 |
|---|---|
| 秘密のヘッダーの確認 | ヘッダーなし・値の違いは 403、一致すれば 200。`<Location "/">` の `Require expr` が `<Directory>` の `Require all granted` を上書きする |
| `RequestHeader unset` の時点 | 秘密のヘッダーの確認の後で効き、Rails には渡らない |
| 利用者の IP の復元 | CloudFront の実際の範囲のアドレス（`130.176.88.20`）から接続して、`REMOTE_ADDR` と `request.remote_ip` が利用者の IP になる |
| 偽の `X-Forwarded-For`・`Client-IP` | 効かない。`RequestHeader unset` を外すと、Rails 4.2 の `remote_ip` は偽の値を選ぶ |
| Rails の HTTPS の認識 | `X-Forwarded-Proto` なしで HTTPS と扱われる |
| `PassengerEnabled off` | `/.well-known/acme-challenge` のファイルが Rails を通らずに返る |
| `old_app_a` | `Alias` と `<Location>` の形で動き、URL に `/old_app_a` が付く |
| TLS の接続名（SNI）と Host が違う場合 | SNI が別の名前でも、SNI がなくても 200 |
| `KeepAliveTimeout 10` | 無通信で 10 秒後に閉じる |

## 確かめること（動かしていない点）

| 項目 | 内容 |
|---|---|
| 実際の CloudFront | Host の受け渡しと証明書の確認が、ドキュメントどおりに動くこと |
| `old_app_a` の配置 | 本物の配置（`/var/www/html` の下のシンボリックリンクなど）に合わせること |
| Let's Encrypt | 今の `AL2` の certbot の設定（webroot のパス）で `--dry-run` が通ること |

## 参考

AWS と Apache のドキュメントと照らし合わせた（2026-11-09）。

- [Require HTTPS between CloudFront and your custom origin](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-https-cloudfront-to-custom-origin.html)
- [Request and response behavior for custom origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html)
- [Add custom headers to origin requests](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/add-origin-custom-headers.html)
- [Syntax for AWS IP address range JSON](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ip-syntax.html)
- [AWS Certificate Manager exportable public certificates](https://docs.aws.amazon.com/acm/latest/userguide/acm-exportable-certificates.html)
- [Managed automation with integrated services（ACME の記述）](https://docs.aws.amazon.com/acm/latest/userguide/acm-services.html)
- [Apache mod_remoteip](https://httpd.apache.org/docs/2.4/mod/mod_remoteip.html)
- [Passenger の設定リファレンス（PassengerEnabled）](https://www.phusionpassenger.com/library/config/apache/reference/)
