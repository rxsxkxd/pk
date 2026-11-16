# ステップ 2: CloudFront のルーティング

> 位置付け: B. CloudFront → EC2 への移行の 3 つのステップの 2 つ目。CloudFront のディストリビューション、オリジンの名前、オリジン用のセキュリティグループを用意し（ステップ 1.5 の WAF の web ACL を関連付ける）、**利用者のドメイン名の DNS を変えずに**、CloudFront 経由でアプリが動くことを確かめる。前は [ステップ 1.5: WAF の web ACL](./step1-5-waf.md)（省略したなら [ステップ 1](./step1-acm-certificate.md)）、次は [ステップ 3: 向き先の変更](./step3-dns-switch.md)。全体は [README](./README.md#3-つのステップ)。
>
> 確かめた範囲: AWS の仕様は AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-11）。定義は CDK の合成と、合成したテンプレートの `cfn-lint` まで確かめた（2026-11-12）。`cdk` の CLI のコマンドは AWS のドキュメントで確かめた（2026-11-13）。**AWS のコマンドと `cdk` の CLI は実行しておらず、実際の CloudFront・WAF では試していない**。`app.example.com`・`origin.app.example.com`・`dxxxx.cloudfront.net` は例で、`<...>` は環境に合わせて置き換える。
>
> 作成日: 2026-11-12（`cloudfront-to-ec2.md`・`cloudfront-to-ec2-same-domain.md`・`external-dns-certificate.md`・`definitions.md` から集めた。CDK のデプロイの 2 通りの仕方を書いた: 2026-11-13。WAF をステップ 1.5 に分け、節の番号を振り直した: 2026-11-16）

## 用語

[README の用語](./README.md#用語)に加えて、次の語を使う。

| 用語 | 指すもの |
|---|---|
| ディストリビューションのドメイン名 | CloudFront がディストリビューションに付ける名前（`dxxxx.cloudfront.net`）。スタックの出力 `DistributionDomainName` |
| 海外の確認用の端末 | 日本以外のリージョン（例 `us-west-2`）に一時的に置く EC2 か Lambda。WAF の国の絞り込みを確かめるために使う |

## このステップの結果

- CloudFront が `app.example.com` を代替ドメイン名として受け、オリジンの名前（`origin.app.example.com`）経由で稼働サーバーの 443 番へ HTTPS で接続できる
- ステップ 1.5 の WAF の web ACL が CloudFront に付いている（ステップ 1.5 を省略したなら付いていない）
- 利用者のドメイン名は、まだ稼働サーバーの Elastic IP を指している。**利用者への影響はない**

## 行うこと

**定義は CDK で扱う**（WAF のルールと CloudFront の設定の量が多く、設定値ファイル 1 つにまとめられるため。[README の T9](./README.md#決めたこと)）。CDK の準備と設定値ファイル、変更セットの 2 通りの作り方は、[ステップ 1.5 の 1.5-0](./step1-5-waf.md#15-0-cdk-の準備と設定値ファイル)（ステップ 1.5 を省略しても、1.5-0 は行う）。**どちらも、端末で行うのは変更セットを作るところまでで、中身の確認と実行は AWS のコンソールで行う**（[変更セットをコンソールで実行する](./definitions.md#変更セットをコンソールで実行する)。[README の T11](./README.md#決めたこと)）。どちらも `cdk bootstrap` はしない。同じ内容の CloudFormation の YAML（`step2-cloudfront.yml`）もあるが、この手順では使わない。

| # | 行うこと | リージョン | CDK のスタック |
|---|---|---|---|
| 2-1 | オリジンの名前（`origin.app.example.com` → Elastic IP）を作る | — | ステージングは 2-2 のスタックで作れる。本番は外部の DNS サービスに手で足す |
| 2-2 | CloudFront とオリジン用のセキュリティグループを作る | `ap-northeast-1` | `<prefix>-step2-cloudfront` |
| 2-3 | オリジン用のセキュリティグループを稼働サーバーに**足す** | `ap-northeast-1` | なし（AWS CLI） |
| 確認 2 | DNS を変えずに、CloudFront 経由で確かめる | — | — |

## 2-1. オリジンの名前

| 名前 | 種類 | 値 |
|---|---|---|
| `origin.app.example.com` | A | 稼働サーバーの Elastic IP |

| | ステージング（Route 53） | 本番（外部の DNS サービス） |
|---|---|---|
| 作り方 | 設定値 `origin_hosted_zone_id`・`origin_elastic_ip` を書くと、2-2 のスタックが作る | 2 つの設定値を空にして、外部の DNS サービスに手で足す。2-2 より前に足してよい |

オリジンの名前は、利用者のドメイン名と**別の名前**にする。同じ名前にすると CloudFront が自分自身に接続することになり、稼働サーバーへ届かない（CDK は合成のときに止める）。

## 2-2. CloudFront とオリジン用のセキュリティグループ

`cloudfront_web_acl_arn`（ステップ 1.5 の `WebAclArn`。省略したなら空）を書いた設定値ファイルで、[1.5-0](./step1-5-waf.md#15-0-cdk-の準備と設定値ファイル) のどちらかの方法で変更セットを作り、コンソール（`ap-northeast-1`）で実行する（どちらの方法も、流すたびに設定値ファイルから合成し直す）。秘密のヘッダーの値だけは、設定値ファイルに書かず、デプロイのときのパラメータで渡す（テンプレートに残さないため）。2 回目以降の更新では、渡さなければ前の値のまま（どちらの方法でも）。

```bash
# 方法 1: CDK で変更セットを作る
cdk diff   -c config=config.yml <prefix>-step2-cloudfront
cdk deploy -c config=config.yml <prefix>-step2-cloudfront --method=prepare-change-set \
  --parameters "<prefix>-step2-cloudfront:OriginVerifyHeaderValue=<準備の 4 で作った値>"

# 方法 2: CloudFormation のテンプレート（YAML）を出して、AWS CLI で変更セットを作る
cdk synth -c config=config.yml <prefix>-step2-cloudfront > templates/<prefix>-step2-cloudfront.template.yml
aws cloudformation deploy --region ap-northeast-1 --no-execute-changeset \
  --template-file templates/<prefix>-step2-cloudfront.template.yml \
  --stack-name <prefix>-step2-cloudfront \
  --parameter-overrides OriginVerifyHeaderValue=<準備の 4 で作った値>

# どちらの方法でも、この後、コンソールで変更セットを確かめて実行する（ディストリビューションの作成に時間がかかる）
```

`cloudfront_certificate_arn` が空だと、このスタックは合成されない（標準エラーに「定義しなかったスタック」と出る。`cdk synth <スタック名>` は `No stacks match the name(s)` で止まる。2026-11-13 に確かめた）。

ディストリビューションの主な設定（定義に入っている）:

| 項目 | 設定 | 理由 |
|---|---|---|
| 代替ドメイン名 | `app.example.com` | 利用者のドメイン名のまま受ける |
| 証明書 | ステップ 1 の証明書。TLSv1.2_2021 | |
| オリジン | `origin.app.example.com`、**HTTPS only**、TLSv1.2 | CloudFront から稼働サーバーまではインターネットを通る |
| 秘密のヘッダー | `X-Origin-Verify: <値>` | CloudFront を通らない要求の見分け（httpd での確認はステップ 3 の片付けで入れる） |
| オリジンの応答タイムアウト | 30 秒（既定） | アプリの最長の応答に合わせる（1〜120 秒） |
| Keep-alive timeout | 5 秒（既定） | httpd の `KeepAliveTimeout` をこれより長くする（準備の 3） |
| 利用者のプロトコル | HTTP を HTTPS へリダイレクト | |
| 許可するメソッド | GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE | フォームと API のため |
| キャッシュポリシー | `CachingDisabled` | 利用者ごとに違う応答を保存しない |
| オリジンリクエストポリシー | **`AllViewer`** | **Host を `app.example.com` のまま渡す**。Cookie、クエリ文字列、`Authorization` も渡す |
| 地理的制限 | **使わない** | 止めた要求が WAF に届かず、確認のパスを例外にできないため |
| WAF | ステップ 1.5 の web ACL（設定値 `cloudfront_web_acl_arn`） | 空なら付けない |
| IPv6 | 無効 | ステップ 3 の DNS のレコードは A だけでよい |

**注意**:

- オリジンの応答がタイムアウトしたとき、`GET`・`HEAD` は CloudFront が再試行する（既定で最大 3 回）。`GET` で状態を変える処理があれば、二重に実行されることがある。`POST` などは再試行しない
- 静的なファイルをキャッシュするなら、落ち着いてから `/assets/*` などのビヘイビアを足す

## 2-3. オリジン用のセキュリティグループを稼働サーバーに足す

2-2 の出力 `OriginSecurityGroupId`（CloudFront のプレフィックスリストから 443 番を許可するグループ）を、稼働サーバーに**足す**。`modify-instance-attribute --groups` は全部を置き換えるので、今のグループも並べる。**今の `0.0.0.0/0` などの許可は残す**（ステップ 3 の片付けで消す）。

```bash
aws ec2 describe-instances --instance-ids <インスタンス ID> \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text
aws ec2 modify-instance-attribute --instance-id <インスタンス ID> \
  --groups <今のグループ…> <OriginSecurityGroupId>
```

## 確認 2（ステップ 3 へ進む条件）

DNS を変える前に、ディストリビューションのドメイン名へ、利用者のドメイン名として接続して確かめる。`--connect-to` は、名前（SNI と Host）を `app.example.com` のまま、接続先だけを CloudFront にする。

```bash
# ディストリビューションのドメイン名と状態（Deployed になるまで待つ）
aws cloudformation describe-stacks --region ap-northeast-1 --stack-name <prefix>-step2-cloudfront \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionDomainName'].OutputValue" --output text
aws cloudfront list-distributions \
  --query "DistributionList.Items[?DomainName=='dxxxx.cloudfront.net'].Status" --output text

# ステップ 1 の証明書が CloudFront に付いたこと
aws acm describe-certificate --region us-east-1 --certificate-arn <ステップ 1 の ARN> \
  --query 'Certificate.{Status:Status,InUseBy:InUseBy,RenewalEligibility:RenewalEligibility}'

# オリジンの名前
dig +short origin.app.example.com

# CloudFront 経由の接続
curl -sv --connect-to app.example.com:443:dxxxx.cloudfront.net:443 https://app.example.com/ -o /dev/null
```

| 確認 | 期待 |
|---|---|
| スタック | `<prefix>-step1-5-waf`（ステップ 1.5）・`<prefix>-step2-cloudfront` が `CREATE_COMPLETE`、ディストリビューションが `Deployed` |
| ステップ 1 の証明書（ACM のコンソールの欄） | `Status`（ステータス）が `ISSUED`（発行済み）のまま。`InUseBy`（使用中ですか?）にこのディストリビューションの ARN が入る（はい）。`RenewalEligibility`（更新の適格性）が `ELIGIBLE`（対象）になる（1-A の場合。ACM が自動で更新するようになる。1-B の登録した証明書は `INELIGIBLE` のまま）。`ELIGIBLE` への変わり方（すぐか、時間がかかるか）は確かめていない |
| オリジンの名前 | `origin.app.example.com` が稼働サーバーの Elastic IP を返す |
| 利用者に見える証明書 | ステップ 1 の ACM の証明書（発行元が Amazon）で、名前の誤りがない |
| 応答の見出し | `Via` に `cloudfront.net`、`X-Cache` が `Miss from cloudfront` |
| ログイン、フォームの送信、ファイルのアップロード | 動く（ブラウザで確かめるなら、手元の `/etc/hosts` に CloudFront の IP を一時的に書く） |
| リダイレクト先 | `https://app.example.com/...`（`origin.app.example.com` が出ない） |
| `old_app_a` | `https://app.example.com/old_app_a/` が動く |
| 稼働サーバーの `access.log` の送り元 | 利用者（手元）の IP になる（CloudFront の IP ではない） |
| 502 が出るとき | オリジンの証明書（名前の不一致、期限切れ、中間証明書の不足）か、セキュリティグループ（2-3） |

ステップ 1.5 の WAF は、海外の確認用の端末から同じく `--connect-to` で確かめる（ステップ 1.5 を省略したなら飛ばす）。`--path-as-is` は、curl が `..` を手元で消さないようにするため。

| 送り元 | 要求（どれも `--connect-to app.example.com:443:dxxxx.cloudfront.net:443` を付ける） | 期待 |
|---|---|---|
| 海外 | `curl -sI https://app.example.com/` | 403（WAF） |
| 海外 | `curl -sI https://app.example.com/.well-known/acme-challenge/test` | httpd の 404（WAF を通った） |
| 海外 | `curl -sI --path-as-is https://app.example.com/.well-known/acme-challenge/../../` | 403 |
| 海外 | `curl -sI --path-as-is https://app.example.com/.well-known/acme-challenge/%2e%2e/%2e%2e/` | 403 |
| 国内 | `curl -sI https://app.example.com/` | アプリの応答 |
| 例外の IP（あれば） | `curl -sI https://app.example.com/` | アプリの応答 |

止めた件数と例は、web ACL の CloudWatch のメトリクス（ルールごと）と、サンプルのリクエスト（WAF のコンソールの web ACL の画面）で見られる。全件のログは既定では残さない（[オプション](./options/waf-managed-rules.md#ログ)）。

## 元に戻す

利用者への影響はない。逆の順で消す。

1. 稼働サーバーから `OriginSecurityGroupId` を外す（`modify-instance-attribute --groups <今のグループ…>`。付けたままだとグループを消せず、スタックの削除が失敗する）
2. コンソールで `<prefix>-step2-cloudfront` を消す（`ap-northeast-1`）。ディストリビューションの無効化と削除に時間がかかる
3. 本番で手で足した `origin.app.example.com` を消す
4. WAF もやめるなら、[ステップ 1.5 の元に戻す](./step1-5-waf.md#元に戻す)（CloudFront を消した後でないと消せない）

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-16）。ACM の欄の意味の参考は [ステップ 1 の参考](./step1-acm-certificate.md#参考)。CDK の CLI の参考は [cdk/python/README.md の参考](./cdk/python/README.md#参考)。WAF の参考は [definitions.md の参考](./definitions.md#参考)。

- [Require HTTPS between CloudFront and your custom origin](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-https-cloudfront-to-custom-origin.html)
- [Origin settings（Origin domain は公開の DNS 名）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesOrigin.html)
- [Cache behavior settings](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesCacheBehavior.html)
- [Use managed cache policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html)
- [Use managed origin request policies（AllViewer）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html)
- [Add custom headers to origin requests](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/add-origin-custom-headers.html)
- [Locations and IP address ranges of CloudFront edge servers](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html)
- [AWS-managed prefix lists（weight）](https://docs.aws.amazon.com/vpc/latest/userguide/working-with-aws-managed-prefix-lists.html)
- [Geographic match rule statement（地理的制限で止めた要求は WAF に届かない）](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-geo-match.html)（2026-11-11）
