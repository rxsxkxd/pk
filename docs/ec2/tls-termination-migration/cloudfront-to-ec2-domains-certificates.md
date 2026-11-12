# CloudFront → EC2 のドメイン名・証明書・通信の流れ

> 位置付け: 参考。採用した B. CloudFront → EC2（利用者のドメイン名を変えない形）で使うドメイン名・DNS のレコード・証明書の役割と、通信の流れをまとめる。作業の順番は [README の 3 つのステップ](./README.md#3-つのステップ)。
>
> 確かめた範囲: AWS の仕様は AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-10）。httpd の側は、今の構成に近いコンテナで確かめた（2026-11-10）。**実際の CloudFront・ACM・Route 53 では試していない**。
>
> `app.example.com`・`origin.app.example.com` は例である。
>
> 作成日: 2026-11-11（`cloudfront-to-ec2-same-domain.md` の通信の流れと確かめたことを統合した: 2026-11-12）

## 用語

| 用語 | 指すもの |
|---|---|
| 利用者のドメイン名 | 利用者が使う名前（`app.example.com`）。移行の前後で変わらない |
| オリジンの名前 | CloudFront が EC2 へ接続するためだけに使う名前（`origin.app.example.com`） |
| 稼働サーバー | CloudFront の接続先の EC2（httpd） |
| CloudFront の証明書 | 利用者と CloudFront の間で使う証明書。ACM で管理する（ACM のコンソールの「証明書」。「ACME 証明書」ではない） |
| オリジンの証明書 | CloudFront と稼働サーバーの間で使う証明書。今の Let's Encrypt の証明書 |

## 全体

```mermaid
%%{init: {"themeVariables": {"fontSize": "16px"}, "flowchart": {"wrappingWidth": 420}}}%%
flowchart TD
  U["利用者"]
  CF["CloudFront<br/>CloudFront の証明書: ACM（us-east-1）の app.example.com"]
  EC2["稼働サーバー（httpd）<br/>オリジンの証明書: Let's Encrypt の app.example.com"]
  D1["DNS: app.example.com → CloudFront"]
  D2["DNS: origin.app.example.com → Elastic IP"]

  U -- "名前を引く" --> D1
  U -- "HTTPS。Host: app.example.com" --> CF
  CF -- "名前を引く" --> D2
  CF -- "HTTPS。Host: app.example.com のまま" --> EC2
```

**証明書はサーバーではなくドメイン名に紐づく**。同じ `app.example.com` の証明書を、CloudFront と稼働サーバーに別々に置ける。オリジンの証明書を CloudFront へ移す必要はない。

## DNS のレコード

| レコード | 今 | 移行後 | 作り方 |
|---|---|---|---|
| `app.example.com` | 稼働サーバーの Elastic IP | CloudFront（Route 53 ならエイリアスの A レコード。IPv6 を有効にしたら AAAA も） | [ステップ 3](./step3-dns-switch.md) で AWS CLI で変える。定義には含めない。外部の DNS サービスなら CNAME |
| `origin.app.example.com` | なし | 稼働サーバーの Elastic IP（A レコード） | [ステップ 2](./step2-cloudfront.md#2-2-オリジンの名前) で新しく作る。Route 53 なら `step2-cloudfront.yml` で作れる（`OriginHostedZoneId`）。外部の DNS サービスなら手で足す |
| ACM の検証用の CNAME（`_<文字列>.app.example.com`） | なし | ACM が示す値 | [ステップ 1](./step1-acm-certificate.md#1-a-acm-で作成する採用) の証明書のスタックの作成中に足す。Route 53 なら自動で作られる（`HostedZoneId`）。外部の DNS サービスなら手で足す。**ACM が自動で更新するために残しておく** |

| 注意 | 内容 |
|---|---|
| オリジンの名前は利用者のドメイン名と別にする | `app.example.com` は CloudFront を指すので、CloudFront の接続先に使うと自分自身に戻る。定義はデプロイ（CDK は合成）のときに止める |
| オリジンに IP アドレスは指定できない | オリジンには公開の DNS で引ける名前が要る。EC2 のパブリック DNS 名でもよい |
| apex（`example.com`）の場合 | CNAME はサブドメインにしか作れない。apex を CloudFront へ向けるには Route 53 のエイリアスが要る |
| 切り替えの前に TTL を短くする | `app.example.com` の TTL を短くして、元の TTL が過ぎるまで待つ |

## 証明書

| 項目 | CloudFront の証明書 | オリジンの証明書 |
|---|---|---|
| 置き場所 | CloudFront | 稼働サーバーの httpd |
| 発行・管理 | ACM | Let's Encrypt（certbot） |
| リージョン | **`us-east-1`**（CloudFront の決まり） | — |
| ドメイン名 | `app.example.com` | `app.example.com`（今のまま） |
| 用意のしかた | **ACM で作成する（DNS 検証。採用）**。既存の証明書の登録もできる（[ステップ 1 の 1-B](./step1-acm-certificate.md#1-b-既存の証明書を登録するオプション)） | 今のものを使い続ける |
| 更新 | ACM が自動で行う（検証の CNAME が残っていて、証明書が使われている間） | certbot が行う（更新の経路は [下の節](#オリジンの証明書の更新)） |
| 確かめる相手 | 利用者のブラウザ | CloudFront |
| 切れたとき | 利用者に証明書の警告が出る | **すべての利用者に 502 が返る** |
| 定義 | `step1-certificate.yml`（ステップ 1） | なし（稼働サーバーの上） |

## どの接続で、何が確かめられるか

| 接続 | 接続先 | 返る証明書 | 確かめること |
|---|---|---|---|
| 利用者 → CloudFront | `app.example.com`（CloudFront） | CloudFront の証明書 | 信頼された CA の証明書で、`app.example.com` に一致すること |
| CloudFront → 稼働サーバー | `origin.app.example.com` の IP | オリジンの証明書 | 信頼された CA の証明書で、期限内で、中間証明書がそろい、**Host の `app.example.com` に一致すること** |

CloudFront がオリジンの証明書で確かめる名前は、「オリジンの名前」か「Host を渡しているならその Host の名前」のどちらかである。この構成は `AllViewer` で Host を渡すので、オリジンの証明書は `app.example.com` に一致すればよく、`origin.app.example.com` を含める必要はない。

| 崩れると | 結果 |
|---|---|
| `AllViewer` をやめて Host を渡さない | オリジンの証明書が `origin.app.example.com` に一致する必要があり、一致しなければ 502 になる |
| オリジンの証明書が自己署名、期限切れ、中間証明書の不足・順序の誤り | CloudFront が接続を切り、502 になる |

CloudFront がオリジンへの TLS で送る名前（SNI）は、AWS のドキュメントでは確かめられなかった。コンテナの httpd は、SNI が別の名前でも、SNI がなくても 200 を返した。

## 通信の流れ

| # | 動作 | 確認されるもの |
|---|---|---|
| 1 | 利用者が `app.example.com` を DNS で引き、CloudFront のアドレスを得る | |
| 2 | 利用者が CloudFront に HTTPS で接続する | CloudFront の証明書が `app.example.com` に一致すること |
| 3 | CloudFront が、オリジンの設定の `origin.app.example.com` を DNS で引き、稼働サーバーの Elastic IP を得る | |
| 4 | CloudFront が稼働サーバーに HTTPS で接続する。`AllViewer` により Host は `app.example.com` のまま | オリジンの証明書が信頼された CA のもので、Host の `app.example.com` に一致すること |
| 5 | httpd が Host を見て、`ServerName app.example.com` の VirtualHost で処理する | CloudFront が付けた秘密のヘッダー（ステップ 3 の片付けの後） |
| 6 | Rails が応答を生成する。Host が同じなので、リダイレクト先の URL は `https://app.example.com/...` になる | |

## 前提が崩れたときに起きること

| 状況 | 結果 |
|---|---|
| オリジンに `app.example.com` を指定する | CloudFront が自分自身のアドレスを引くことになり、稼働サーバーへ届かない |
| `AllViewer` をやめて Host を渡さない | Host がオリジンの名前になる。オリジンの証明書が `origin.app.example.com` に一致する必要があり、一致しなければ 502 になる。Rails のリダイレクト先もオリジンの名前になる |
| オリジンの証明書が切れる | すべての利用者に 502 が返る |
| 稼働サーバーが中間証明書を返さない、順序が違う | CloudFront が接続を切り、502 になる |
| DNS の切り替えが行き渡る前に秘密のヘッダーの確認を入れる | まだ稼働サーバーへ直接来ている利用者が 403 になる |

## オリジンの証明書の更新

今は HTTP-01（80 番の `/.well-known/acme-challenge/`）で更新している。移行の後は `app.example.com` が CloudFront を指すので、Let's Encrypt の確認は CloudFront を通る。

**WAF で国を絞り、`/.well-known/acme-challenge/` だけを例外にすると決めた（2026-11-11）**。EC2 の Let's Encrypt の証明書と HTTP-01 の更新は、今のまま続ける。CloudFront の地理的制限は使わない（地理的制限で止めた要求は WAF に届かないので、パスの例外を作れない）。定義は [definitions.md](./definitions.md#ステップ-2-の-waf国の絞り込み)。

| 方法 | 内容 | 注意 |
|---|---|---|
| **地理的制限の代わりに WAF を使う（採用）** | 国で絞りつつ、`/.well-known/acme-challenge/` だけを例外にできる | WAF の料金（web ACL とルール 5 つで月 $10 の見込みと、100 万リクエストごとに $0.60。ほかにログの料金）。httpd の 443 番に確認のパスの設定が要る（[証明書の更新](./cloudfront-to-ec2-httpd.md#証明書の更新)） |
| DNS-01 に変える（見送り） | CloudFront の設定に左右されない | DNS の API の権限の持たせ方を決める |
| オリジンの証明書を ACM のものにする（見送り） | ACM の ACME かエクスポートできる証明書 | この用途では試していない。エクスポートできる証明書は有料 |

CloudFront の証明書（ACM）は、どの方法でも影響を受けない。

## 移行の間

| 時点 | CloudFront の証明書 | オリジンの証明書 | 利用者への影響 |
|---|---|---|---|
| ACM の発行（DNS の切り替えの前） | 発行される | 今のまま | なし |
| DNS の切り替えが行き渡るまで | CloudFront 経由の利用者が使う | 直接来る利用者と、CloudFront が使う | なし（どちらの経路でも証明書が有効） |
| 切り替えの後 | 利用者が使う | CloudFront だけが使う | なし |

オリジンの証明書を移動しないので、切り替えの間も証明書の差し替えは起きない。

## 残り日数の確かめ方

| 証明書 | 確かめ方 |
|---|---|
| CloudFront の証明書 | ACM の `DaysToExpiry`（CloudWatch のメトリクス） |
| オリジンの証明書 | 踏み台サーバーから [`cert-expiry-check.sh`](../port-guard-rollout/certificate-expiry-check.md) で稼働サーバーの 443 番へ接続する。稼働サーバーのセキュリティグループを CloudFront のプレフィックスリストに絞った後も、踏み台サーバーからの 443 番の許可を残す |

## 確かめたこと・確かめていないこと

コンテナで確かめた内容（秘密のヘッダーの確認、利用者の IP の復元、Rails の HTTPS の認識、SNI と Host が違う場合など。2026-11-10）は [cloudfront-to-ec2-httpd.md の検証の結果](./cloudfront-to-ec2-httpd.md#検証の結果)。コンテナの証明書は自己署名で、接続時に検証していない。

| 確かめていない | 内容 |
|---|---|
| CloudFront の実際の動作 | 実際のディストリビューションで、`AllViewer` の Host の受け渡しと証明書の確認が、ドキュメントどおりに動くこと（[ステップ 2 の確認 2](./step2-cloudfront.md#確認-2ステップ-3-へ進む条件)） |
| CloudFront が TLS で送る名前（SNI） | `AllViewer` のときに利用者のドメイン名を送るかは、AWS のドキュメントで確かめられなかった |
| Let's Encrypt の更新 | CloudFront と WAF を経た HTTP-01 が通ること（[ステップ 3 の片付け](./step3-dns-switch.md#3-5-片付け)の 3） |
| 本物のアプリ | Cookie、CSRF のトークン、ファイルのアップロードなど |

本番の前に、ステージングで 3 つのステップを 1 度通して確かめる。

## 決めること

| # | 論点 |
|---|---|
| C1 | オリジンの証明書の更新の方法 → **WAF で確認のパスを例外にし、HTTP-01 を続ける**（2026-11-11 に決めた） |
| C2 | `app.example.com` の DNS が Route 53 か → **ステージングは Route 53、本番は別のサービス**（2026-11-11）。ステージングは `HostedZoneId`・`OriginHostedZoneId` を指定して定義で作る。本番は空にして、ACM の検証の CNAME と `origin.app.example.com` を、その DNS のサービスに手で足す（各ステップの外部の DNS サービスの節） |
| C3 | ドメインに CAA レコードがあるか。あれば ACM の発行を許可する必要がある（AWS のドキュメントでは確かめられなかった）。確かめ方は [準備の 1](./step0-preparation.md#1-事前の確認) |

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-10）。

- [Require HTTPS between CloudFront and your custom origin（オリジンの証明書の名前と検証）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-https-cloudfront-to-custom-origin.html)
- [Origin settings（Origin domain）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesOrigin.html)
- [Requirements for using SSL/TLS certificates with CloudFront（us-east-1）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html)
- [Use managed origin request policies（AllViewer）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html)
- [Routing traffic to a CloudFront distribution（エイリアス、apex）](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-to-cloudfront-distribution.html)
- [AWS Certificate Manager DNS validation（検証の CNAME と自動更新）](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html)
- [AWS::CertificateManager::Certificate（Route 53 での自動検証）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-certificatemanager-certificate.html)
- [Supported CloudWatch metrics（ACM の DaysToExpiry）](https://docs.aws.amazon.com/acm/latest/userguide/cloudwatch-metrics.html)
- [Geographic match rule statement（CloudFront の地理的制限で止めた要求は WAF に届かない）](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-geo-match.html)（2026-11-11）
