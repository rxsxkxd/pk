# ステップ 3: 向き先の変更

> 位置付け: B. CloudFront → EC2 への移行の 3 つのステップの 3 つ目。利用者のドメイン名（`app.example.com`）の DNS の向き先を、稼働サーバーの Elastic IP から CloudFront へ変え、落ち着いたら片付ける。**Route 53（ステージング）を本線**にし、シェルスクリプト `scripts/step3-dns-switch.sh` で行う。外部の DNS サービス（本番）は[別の節](#3-3-外部の-dns-サービス本番)に書いた。前は [ステップ 2: CloudFront のルーティング](./step2-cloudfront.md)。全体は [README](./README.md#3-つのステップ)。
>
> 確かめた範囲: Route 53 の仕様は AWS のドキュメントと照らし合わせた（2026-11-09、2026-11-12）。スクリプトは構文の確認（`bash -n`）と、使い方の誤りで止まることだけを確かめた（2026-11-12。macOS の bash 3.2）。**AWS を呼ぶ部分は動かしておらず、実際の Route 53・外部の DNS サービスでは試していない**。`app.example.com`・`dxxxx.cloudfront.net`・`192.0.2.10` は例で、`<...>` は環境に合わせて置き換える。
>
> 作成日: 2026-11-12（`cloudfront-to-ec2.md`・`cloudfront-to-ec2-same-domain.md`・`external-dns-certificate.md` から集めた。シェルスクリプトにした: 2026-11-12）

## 用語

[README の用語](./README.md#用語)に加えて、次の語を使う。

| 用語 | 指すもの |
|---|---|
| 今のレコード | 切り替えの前の `app.example.com` の A レコード（値は稼働サーバーの Elastic IP） |
| エイリアスのレコード | Route 53 の独自の A レコード。値の代わりに CloudFront のディストリビューションを指す |
| 変更バッチ | Route 53 の `change-resource-record-sets` に渡す変更の並び。**全部が行われるか、何も行われないか**のどちらか（AWS のドキュメントの記述） |
| 控えのファイル | スクリプトが切り替えの前に書き出す、今のレコードの JSON（既定 `before-app.example.com-A.json`）。元に戻すときに使う |
| 片付け | 切り替えが行き渡った後に、直接の接続を止める作業（秘密のヘッダーの確認、古い許可の削除など） |

## このステップの結果

- `app.example.com` が CloudFront を指し、利用者の接続がすべて CloudFront と WAF を通る
- 片付けの後は、稼働サーバーへの直接の接続が止まる（セキュリティグループと秘密のヘッダーの確認）

## シェルスクリプトにした理由

CloudFormation（ステップ 1 の形）とシェルスクリプトを比べ、シンプルな方としてシェルスクリプトにした（[README の T8](./README.md#決めたこと)。2026-11-12）。

| | CloudFormation | **シェルスクリプト（採用）** |
|---|---|---|
| 今もある `app.example.com` のレコード | 定義で作るには、先に消す（その間は名前が引けない）か、スタックへの取り込み（インポート）の手順が要る | 今のレコードをそのまま読み、1 つの変更バッチで置き換える |
| 元に戻す | スタックを消し、元のレコードを作り直す（2 段階） | 控えのファイルから逆の変更バッチを流す（1 段階） |
| 中身の確かめ方 | 変更セット | `plan` で流す変更バッチを表示する |

## 行うこと

| # | 行うこと | 利用者への影響 |
|---|---|---|
| 3-1 | 流す変更を確かめる（`plan`） | なし |
| 3-2 | 向き先を CloudFront へ変える（`switch`。Route 53） | 順次 CloudFront 経由になる |
| 3-3 | （本番）外部の DNS サービスで向き先を変える | 同上 |
| 確認 3 | 利用者のドメイン名で CloudFront を通っていることを確かめる | なし |
| 3-4 | 元の TTL より長く待つ | なし |
| 3-5 | 片付け | 直接の接続が止まる |

## スクリプト

`scripts/step3-dns-switch.sh`（AWS CLI v2 と jq を使う）。

| コマンド | 行うこと | AWS を変えるか |
|---|---|---|
| `plan` | 今の A レコードを表示し、流す変更バッチを表示する | 変えない |
| `switch` | 今のレコードを控えのファイルに書き出し、確認の問い合わせの後、今のレコードの DELETE とエイリアスのレコードの CREATE を 1 つの変更バッチで流し、`INSYNC` になるまで待つ | 変える |
| `rollback` | 控えのファイルを読み、確認の問い合わせの後、エイリアスのレコードの DELETE と控えたレコードの CREATE を 1 つの変更バッチで流し、`INSYNC` になるまで待つ | 変える |

止まる場合（終了コード 1。何も変えない）:

| 状況 | 理由 |
|---|---|
| `app.example.com` に AAAA レコードがある | スクリプトは A だけを扱う。ステップ 2 の CloudFront は IPv6 を無効にしているので、AAAA は作らない。今 AAAA があるなら、扱いを先に決める |
| A レコードが 1 件でない、またはエイリアスやルーティングポリシー付き（`switch`） | 単純な A（値は Elastic IP）を前提にしている |
| 控えのファイルがすでにある（`switch`） | 前の控えを上書きしないため。中身を確かめてから消すか、`--backup` で別の名前にする |
| 今の A が CloudFront を指すエイリアスでない（`rollback`） | 戻すものがないか、手で変えられている |

すでに CloudFront を指しているときは、何もせずに終了コード 0 で終わる。変更バッチの DELETE は今の値と完全に一致しないと失敗し、そのときは変更バッチ全体が行われず、何も変わらない。

変更バッチの中身（`switch` の場合）:

| 項目 | 値 | 理由 |
|---|---|---|
| DELETE | 今のレコード（読み出したものをそのまま） | 値が一致しないと失敗し、何も変わらない |
| CREATE の `AliasTarget.HostedZoneId` | **`Z2FDTNDATAQYW2`** | CloudFront を指すエイリアスは、この値に決まっている（AWS のドキュメントの記述）。ディストリビューションごとに変わらない |
| CREATE の `AliasTarget.DNSName` | `--distribution` の値（ステップ 2 の出力 `DistributionDomainName`） | |
| CREATE の `EvaluateTargetHealth` | `false` | CloudFront を指すエイリアスでは `true` にできない |

エイリアスのレコードにできるのは公開のホストゾーンだけで、CloudFront の代替ドメイン名に `app.example.com` が入っている必要がある（ステップ 2 で入れた）。

## 3-1. 流す変更を確かめる

```bash
ZONE=<app.example.com のホストゾーン ID>
DIST=$(aws cloudformation describe-stacks --region ap-northeast-1 --stack-name <prefix>-step2-cloudfront \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionDomainName'].OutputValue" --output text)

scripts/step3-dns-switch.sh plan --zone-id "$ZONE" --name app.example.com --distribution "$DIST"
```

表示された今のレコードの値（Elastic IP）と TTL（準備の 2 で短くしたもの）、変更バッチの中身を確かめる。

## 3-2. 向き先を CloudFront へ変える（Route 53。ステージング）

```bash
scripts/step3-dns-switch.sh switch --zone-id "$ZONE" --name app.example.com --distribution "$DIST"
```

控えのファイル（`before-app.example.com-A.json`）は、片付けが終わるまで消さずに置いておく。`INSYNC` までは通常 60 秒以内（AWS のドキュメントの記述）。

## 3-3. 外部の DNS サービス（本番）

外部の DNS サービスにはスクリプトを使えない。エイリアスの代わりに CNAME を使い、手で変える。

| 名前 | 今 | 変えた後 |
|---|---|---|
| `app.example.com` | A（稼働サーバーの Elastic IP） | CNAME（`dxxxx.cloudfront.net`） |

- 同じ名前に A と CNAME は並べられないので、A を消して CNAME を足す（サービスによっては種類の変更で行う）。消してから足すまでの間は名前が引けないので、間を空けない。サービスが種類の変更をまとめて行えるなら、そちらを使う
- `app.example.com` は名前の頭に `app.` が付いているので、CNAME にできる。**`example.com` そのもの（ゾーンの頂点）は、DNS の決まりで CNAME にできない**。頂点を向けるなら、外部の DNS サービスに ALIAS・ANAME・CNAME flattening などの機能があるかで決まる
- 変える前の A の値と TTL を控えておく（元に戻すため）

## 確認 3（片付けへ進む条件）

```bash
# 権威のある DNS サーバーと、手元のリゾルバーの両方で見る
dig +short NS example.com
dig +short app.example.com @<上の NS の 1 つ>
dig +short app.example.com

curl -sI https://app.example.com/
```

| 確認 | 期待 |
|---|---|
| 名前の解決 | CloudFront のアドレス（`dxxxx.cloudfront.net` と同じ範囲）が返る。外部の DNS サービスなら CNAME が返る |
| 応答の見出し | `Via` に `cloudfront.net` |
| 利用者に見える証明書 | ACM の証明書（ステップ 1） |
| 稼働サーバーの `access.log` | 新しい要求の送り元が利用者の IP（CloudFront の範囲ではない） |
| WAF | 海外の確認用の端末から 403（[ステップ 2 の確認 2](./step2-cloudfront.md#確認-2ステップ-3-へ進む条件) と同じ。`--connect-to` は要らない） |
| エラーの割合 | CloudFront の 4xx・5xx の割合（CloudWatch のメトリクス）が増えていない |

問題があれば、[元に戻す](#元に戻す)。

## 3-4. 待つ

元の TTL（準備の 2 で短くする前の値）より長く待つ。その間は、古い名前の解決を持っている利用者が、まだ稼働サーバーへ直接来る。直接の接続を止める片付けは、待ってから行う。

## 3-5. 片付け

| 順番 | 作業 | 確かめ方 |
|---|---|---|
| 1 | 稼働サーバーの httpd の[秘密のヘッダーの確認](./cloudfront-to-ec2-httpd.md#3-秘密のヘッダーを確認する)を有効にする（準備の 4 で作った値） | `curl -sI https://origin.app.example.com/` が 403、`curl -sI https://app.example.com/` がアプリの応答 |
| 2 | 稼働サーバーのセキュリティグループから、`0.0.0.0/0` などの 80・443 番の許可を消す（ステップ 2 の `OriginSecurityGroupId` と、踏み台サーバーからの 443 番の許可は残す） | 手元から稼働サーバーの Elastic IP へ直接つなぐと届かない |
| 3 | オリジンの証明書の更新が新しい経路で成功することを確かめる | `sudo certbot renew --dry-run` |
| 4 | 証明書の残り日数の監視を入れる。**オリジンの証明書が切れると、すべての利用者に 502 が返る** | [残り日数の確かめ方](./cloudfront-to-ec2-domains-certificates.md#残り日数の確かめ方) |
| 5 | 本番の CNAME の TTL を元に戻す（Route 53 のエイリアスのレコードは TTL を持たない） | `dig app.example.com` |
| 6 | （オプションの WAF のマネージドルールを入れるときだけ）count で入れて誤検知を確かめてから `block` にする。既定の WAF には入れていない | [options/waf-managed-rules.md の入れ方](./options/waf-managed-rules.md#入れ方方法論) |
| 7 | 控えのファイルを片付ける（戻す見込みがなくなってから） | |

## 元に戻す

| 時点 | 戻し方 |
|---|---|
| 3-2・3-3 の後、片付けの前 | DNS を今のレコードに戻すだけでよい |
| 片付けの 1 の後 | **先に httpd の秘密のヘッダーの確認を外してから** DNS を戻す（外さないと、直接来る利用者が 403 になる） |
| 片付けの 2 の後 | 消した許可を先に戻してから DNS を戻す |

Route 53 では、`switch` で書いた控えのファイルを使う。

```bash
scripts/step3-dns-switch.sh rollback --zone-id "$ZONE" --name app.example.com
```

外部の DNS サービスでは、CNAME を消して、控えておいた A に戻す。

戻した後も、ステップ 1・2 で作ったもの（証明書、WAF、CloudFront）は残る。やり直すなら、原因を直して確認 2 からもう一度行う（`switch` の前に、前の控えのファイルを片付ける）。全部をやめるなら、[ステップ 2 の元に戻す](./step2-cloudfront.md#元に戻す)、[ステップ 1 の元に戻す](./step1-acm-certificate.md#元に戻す)の順に消す。

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09、2026-11-12）。

- [Routing traffic to a CloudFront distribution（エイリアスのレコード、IPv6 なら A と AAAA、公開のホストゾーンだけ）](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-to-cloudfront-distribution.html)
- [AliasTarget（CloudFront は HostedZoneId に Z2FDTNDATAQYW2、EvaluateTargetHealth は true にできない）](https://docs.aws.amazon.com/Route53/latest/APIReference/API_AliasTarget.html)（2026-11-12）
- [ChangeResourceRecordSets（変更バッチは全部か何も行わない、DELETE は同じ値をすべて書く、INSYNC まで通常 60 秒以内）](https://docs.aws.amazon.com/Route53/latest/APIReference/API_ChangeResourceRecordSets.html)（2026-11-12）
- [aws route53 wait resource-record-sets-changed](https://docs.aws.amazon.com/cli/latest/reference/route53/wait/resource-record-sets-changed.html)
