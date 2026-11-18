# 準備（ステップ 1 の前）

> 位置付け: B. CloudFront → EC2 への移行の、ステップ 1 より前に行う準備。全体は [README](./README.md#ステップの流れ)。次は [ステップ 1: ACM の証明書](./step1-acm-certificate.md)。その後、ステップ 1.5（WAF。省略できる）、ステップ 2、ステップ 3 と進む。
>
> 確かめた範囲: httpd の設定は、今の構成に近いコンテナで確かめた（2026-11-10。[検証の結果](./cloudfront-to-ec2-httpd.md#検証の結果)）。**AWS のコマンドと、本物の稼働サーバーでは試していない**。`app.example.com` は例で、`<...>` は環境に合わせて置き換える。
>
> 作成日: 2026-11-12（`cloudfront-to-ec2.md`・`cloudfront-to-ec2-same-domain.md`・`external-dns-certificate.md` から集めた）

## 用語

[README の用語](./README.md#用語)と同じ（稼働サーバー、利用者のドメイン名、オリジンの名前、秘密のヘッダーなど）。

## この準備で行うこと

| # | 行うこと | 利用者への影響 |
|---|---|---|
| 1 | 事前の確認（DNS の管理先、CAA、アプリ、セキュリティグループの枠） | なし |
| 2 | 利用者のドメイン名の DNS の TTL を短くする | なし |
| 3 | 稼働サーバーの httpd に、**秘密のヘッダーの確認以外**の設定を入れる | なし |
| 4 | 秘密のヘッダーの値を作る | なし |
| 5 | 準備の確認 | なし |

## 1. 事前の確認

```bash
# DNS の管理先（ネームサーバー）。Route 53 か外部の DNS サービスかを確かめる
dig +short NS example.com

# CAA。app.example.com になければ親のドメインが効くので、両方を見る
dig +short CAA app.example.com
dig +short CAA example.com

# 今の向き先と TTL
dig app.example.com
```

| 確かめること | 内容 |
|---|---|
| DNS の管理先と、レコードを変える権限 | ステージングは Route 53、本番は外部の DNS サービス（[README の T7](./README.md#決めたこと)）。外部の DNS サービスで権限がなければ、管理している人に頼む。頼む内容は 3 回ある（ステップ 1 の検証用の CNAME、ステップ 2 のオリジンの名前、ステップ 3 の向き先の変更）。**ステップ 1 の CNAME は、頼んでから 72 時間以内に足してもらう必要がある**（[ステップ 1](./step1-acm-certificate.md#1-a-2-外部の-dns-サービス本番)） |
| CAA | 結果が空なら対応は要らない。`letsencrypt.org` などだけが書かれていると、ACM は発行できない。Amazon を許可する行を足す（Let's Encrypt の行は、オリジンの証明書で使うので残す）。Amazon を許可する値は、AWS のドキュメントで確かめられなかった（2026-11-11）。CAA があったときに確かめる |
| セキュリティグループの枠 | CloudFront のプレフィックスリストは **55 件**に数えられる。既定の上限は 60 件なので、ステップ 2 では専用のグループを作って足す |
| オリジンの名前 | CloudFront の接続先には、公開の DNS で引ける名前が要る（IP アドレスは指定できない）。利用者のドメイン名は CloudFront を指すことになるので、**稼働サーバーの EC2 のパブリック DNS 名**を使う（[README の T13](./README.md#決めたこと)）。`aws ec2 describe-instances` の `PublicDnsName` が空でないことを確かめておく（空なら VPC の DNS ホスト名の設定が無効） |
| アプリ | 応答に 30 秒以上かかる処理（CloudFront のオリジンの応答タイムアウトの既定）、`GET` で状態を変える処理（タイムアウトのとき CloudFront が `GET`・`HEAD` を再試行する）、`Authorization` ヘッダーの利用 |
| IP で直接つないでいる相手 | [README](./README.md#どの手順でも共通して確かめること)のとおり |

## 2. TTL を短くする

利用者のドメイン名（`app.example.com`）の TTL を短く（例: 60 秒）し、**元の TTL が過ぎるまで待つ**。ステップ 3 の切り替えと、元に戻すときの反映が早くなる。ステップ 4 の片付けで元の TTL に戻す。

Route 53 では、今のレコードの値を変えずに TTL だけを変える（`change-resource-record-sets` の `UPSERT`）。今の値は、ステップ 3 のスクリプトの `plan`（[3-1](./step3-dns-switch.md#3-1-流す変更を確かめる)。何も変えない）でも表示できる。

## 3. 稼働サーバーの httpd の設定

[cloudfront-to-ec2-httpd.md](./cloudfront-to-ec2-httpd.md) の設定のうち、**秘密のヘッダーの確認以外**を入れる。秘密のヘッダーの確認は、[ステップ 4](./step4-origin-restriction.md) で入れる（先に入れると、まだ稼働サーバーへ直接来ている利用者が 403 になる）。

| 設定 | 今入れるか | 詳細 |
|---|---|---|
| SSL/TLS の設定を残す、`ServerName` を利用者のドメイン名にする | 今のまま | [1](./cloudfront-to-ec2-httpd.md#1-ssltls-の設定を残す)・[2](./cloudfront-to-ec2-httpd.md#2-servername) |
| 利用者の IP の復元（`mod_remoteip`） | **入れる** | [4](./cloudfront-to-ec2-httpd.md#4-利用者の-ip-を復元する) |
| `KeepAliveTimeout 10` | **入れる** | [5](./cloudfront-to-ec2-httpd.md#5-keepalivetimeout) |
| 443 番の `/.well-known/acme-challenge` | **入れる**（**遅くともステップ 3 の前**。ステップ 3 の後の最初の証明書の更新で使う） | [証明書の更新](./cloudfront-to-ec2-httpd.md#証明書の更新)、[ステップ 3 の始める前に](./step3-dns-switch.md#始める前にステップ-3-へ進む前の条件) |
| 秘密のヘッダーの確認 | **入れない**（ステップ 4） | [3](./cloudfront-to-ec2-httpd.md#3-秘密のヘッダーを確認する) |

これらの設定は、CloudFront を通らない今の直接の接続でも害がない（利用者の IP の復元は、信頼する範囲の CloudFront のアドレスから来た要求だけに効く）。ただし、利用者の IP の復元と一緒に入れる `RequestHeader unset X-Forwarded-For` だけは、今の直接の接続にも効く（下の注意）。

利用者の IP の復元を切り替えの前に入れるのは、CloudFront を通る最初の要求からログとアプリに利用者の IP が出るようにするためと、[ステップ 2 の確認 2](./step2-cloudfront.md#確認-2ステップ-3-へ進む条件)（`access.log` の送り元が自分の IP になる）で効いていることを確かめるためである。後から入れると、切り替えてから入れるまでの間、送り元がすべて CloudFront の IP になる。

| 注意 | 内容 |
|---|---|
| **`X-Forwarded-For` を消すことの影響** | `RequestHeader unset X-Forwarded-For`（[4](./cloudfront-to-ec2-httpd.md#4-利用者の-ip-を復元する)）は、直接来ている要求からも `X-Forwarded-For` を消すので、アプリに届かなくなる。Rails 4.2 の `request.remote_ip` は、`X-Forwarded-For` があるとその値を優先して使うことがある（コンテナで確かめたとき、利用者が偽って付けた値を選んだ）。そのため、会社の proxy などを経由して `X-Forwarded-For` が付いている利用者は、入れた後、`remote_ip` がヘッダーの値から接続の相手の IP（proxy の IP）に変わる。偽れない値になるので正しくなる方向の変化だが、**アプリが `remote_ip` で IP を許可・制限しているなら、該当の利用者で結果が変わる**ことがある |
| 入れる前に確かめること | アプリのコードで `remote_ip`・`request.ip`・`REMOTE_ADDR` を使っている箇所と、その使い道（ログだけか、許可・制限などの判定か）。判定に使っていなければ、影響はない。稼働サーバーの Apache に `mod_remoteip` がない場合の選択肢は [client-ip-restoration.md](./client-ip-restoration.md#古い-apache-で-mod_remoteip-を使えないときの選択肢) |

## 4. 秘密のヘッダーの値を作る

32 文字以上のランダムな値を作り、安全な場所に控える。ステップ 2 で CloudFront のスタックに渡し、ステップ 4 で httpd に入れる。

```bash
openssl rand -hex 32
```

## 5. 準備の確認（ステップ 1 へ進む条件）

| 確認 | コマンド・見るところ | 期待 |
|---|---|---|
| httpd の設定の文法 | `sudo apachectl configtest` | `Syntax OK` |
| 反映 | `sudo apachectl graceful` の後、`curl -sI https://app.example.com/` | 今までどおりアプリの応答 |
| 確認のパス | `curl -sI https://app.example.com/.well-known/acme-challenge/test` | httpd の 404（Rails を通らない） |
| オリジンの証明書の更新 | `sudo certbot renew --dry-run` | 成功（まだ今の経路） |
| TTL | `dig app.example.com` | 短くした TTL が返る。元の TTL が過ぎている |
| CAA | 上の `dig CAA` | 空、または Amazon を許可している |

## 元に戻す

httpd の設定を元のファイルに戻して `apachectl graceful` する。AWS の側は何も作っていない。
