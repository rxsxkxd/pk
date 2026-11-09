# SSL/TLS の終端が httpd であることの確認手順

> 位置付け: Apache（httpd）と Passenger で動く Web サービスについて、443 番の SSL/TLS の終端が httpd であることを確認する手順。
>
> 前提: インスタンスの手前に、ALB・CloudFront など SSL/TLS を終端するものは置いていない。
>
> 確かめた範囲: 設定ファイルの内容からの机上の整理で、この手順のコマンドは実機では流していない。出力の例は想定の形で、実際の環境の出力ではない。
>
> 作成日: 2026-11-09

## 確認すること

| # | 確認すること | 見るもの |
|---|---|---|
| 1 | 443 番の VirtualHost で httpd が SSL/TLS を処理する設定になっている | `/etc/httpd/conf.d/rails.conf` |
| 2 | その VirtualHost が実際に読み込まれている | `apachectl -S` |
| 3 | SSL/TLS を処理するモジュールが読み込まれている | `httpd -M` |
| 4 | 443 番を待ち受けているプロセスが httpd である | `ss -ltnp` |

## 手順

### 1. Apache の設定ファイルを見る

`/etc/httpd/conf.d/rails.conf` の `<VirtualHost *:443>` の中に、次の設定があることを確認する。

| 設定 | 分かること |
|---|---|
| `SSLEngine on` | この VirtualHost で httpd が SSL/TLS を処理する |
| `SSLCertificateFile`、`SSLCertificateKeyFile` | 証明書と秘密鍵を httpd が持っている |
| `PassengerAppRoot` | アプリは httpd の `mod_passenger` の配下で動き、httpd が復号した後のリクエストを受け取る |

```apache
<VirtualHost *:443>
   ServerName aaa
   PassengerAppRoot /home/ruby/new_app_b

   SSLEngine on
   SSLCertificateFile /etc/letsencrypt/live/c/cert.pem
   SSLCertificateKeyFile /etc/letsencrypt/live/c/privkey.pem
   SSLCertificateChainFile /etc/letsencrypt/live/c/chain.pem
</VirtualHost>
```

### 2. VirtualHost が読み込まれていることを確認する

```bash
sudo apachectl -S
```

443 番の VirtualHost として、`/etc/httpd/conf.d/rails.conf` が表示されることを確認する。

```text
*:443    aaa (/etc/httpd/conf.d/rails.conf:<行番号>)
```

`/etc/httpd/conf.d/ssl.conf` にも既定の `_default_:443` の VirtualHost があると、443 番に複数の VirtualHost が表示される。その場合は、`default server` と表示されるものと、`ServerName` が対象のドメインと一致するものも確認する。

### 3. `ssl_module` が読み込まれていることを確認する

```bash
sudo httpd -M | grep ssl
```

次の行が表示されることを確認する。

```text
 ssl_module (shared)
```

### 4. 443 番を httpd が待ち受けていることを確認する

```bash
sudo ss -ltnp | grep ':443'
```

待ち受けているプロセスの名前が `httpd` であることを確認する。

```text
LISTEN 0 511 *:443 *:* users:(("httpd",pid=<プロセス ID>,fd=<番号>),...)
```

## 判定

手順 1〜4 がすべて期待どおりなら、443 番の SSL/TLS の終端は httpd である。

## 補足

- この判定の対象は 443 番だけである。`rails.conf` の `<VirtualHost *:80>` には SSL/TLS の設定も HTTPS へのリダイレクトもなく、`/old_app_a` を平文のまま返す。
- 手前に SSL/TLS を終端するものがないという前提を確かめたいときは、外から見える証明書とサーバーの証明書のフィンガープリントを比べる。一致すれば、利用者が受け取っているのは httpd の証明書である。

```bash
# 外部（作業者の PC など）から。<ドメイン> は実際の名前に置き換える
openssl s_client -connect <ドメイン>:443 -servername <ドメイン> </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256

# サーバーで
sudo openssl x509 -in /etc/letsencrypt/live/c/cert.pem -noout -fingerprint -sha256
```
