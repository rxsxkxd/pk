# ステップ 2: CloudFront のルーティング

> 位置付け: B. CloudFront → EC2 への移行の 3 つのステップの 2 つ目。WAF の web ACL、CloudFront のディストリビューション、オリジンの名前、オリジン用のセキュリティグループを用意し、**利用者のドメイン名の DNS を変えずに**、CloudFront 経由でアプリが動くことを確かめる。前は [ステップ 1: ACM の証明書](./step1-acm-certificate.md)、次は [ステップ 3: 向き先の変更](./step3-dns-switch.md)。全体は [README](./README.md#3-つのステップ)。
>
> 確かめた範囲: AWS の仕様は AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-11）。定義は CDK の合成と、合成したテンプレートの `cfn-lint` まで確かめた（2026-11-12）。`cdk` の CLI のコマンドは AWS のドキュメントで確かめた（2026-11-13）。**AWS のコマンドと `cdk` の CLI は実行しておらず、実際の CloudFront・WAF では試していない**。`app.example.com`・`origin.app.example.com`・`dxxxx.cloudfront.net` は例で、`<...>` は環境に合わせて置き換える。
>
> 作成日: 2026-11-12（`cloudfront-to-ec2.md`・`cloudfront-to-ec2-same-domain.md`・`external-dns-certificate.md`・`definitions.md` から集めた。CDK のデプロイの 2 通りの仕方を書いた: 2026-11-13）

## 用語

[README の用語](./README.md#用語)に加えて、次の語を使う。

| 用語 | 指すもの |
|---|---|
| ディストリビューションのドメイン名 | CloudFront がディストリビューションに付ける名前（`dxxxx.cloudfront.net`）。スタックの出力 `DistributionDomainName` |
| 海外の確認用の端末 | 日本以外のリージョン（例 `us-west-2`）に一時的に置く EC2 か Lambda。WAF の国の絞り込みを確かめるために使う |

## このステップの結果

- CloudFront が `app.example.com` を代替ドメイン名として受け、オリジンの名前（`origin.app.example.com`）経由で稼働サーバーの 443 番へ HTTPS で接続できる
- WAF の web ACL が CloudFront に付いている
- 利用者のドメイン名は、まだ稼働サーバーの Elastic IP を指している。**利用者への影響はない**

## 行うこと

**定義は CDK で扱う**（WAF のルールと CloudFront の設定の量が多く、設定値ファイル 1 つにまとめられるため。[README の T9](./README.md#決めたこと)）。デプロイの仕方は 2 通りあり、環境ごとにどちらかに決める（[2-0](#2-0-cdk-の準備と設定値ファイル)）。どちらも `cdk bootstrap` はしない。同じ内容の CloudFormation の YAML（`step2-waf.yml`・`step2-cloudfront.yml`）もあるが、この手順では使わない。

| # | 行うこと | リージョン | CDK のスタック |
|---|---|---|---|
| 2-0 | CDK の準備と設定値ファイル | — | — |
| 2-1 | WAF の web ACL を作る | `us-east-1` | `<prefix>-step2-waf` |
| 2-2 | オリジンの名前（`origin.app.example.com` → Elastic IP）を作る | — | ステージングは 2-3 のスタックで作れる。本番は外部の DNS サービスに手で足す |
| 2-3 | CloudFront とオリジン用のセキュリティグループを作る | `ap-northeast-1` | `<prefix>-step2-cloudfront` |
| 2-4 | オリジン用のセキュリティグループを稼働サーバーに**足す** | `ap-northeast-1` | なし（AWS CLI） |
| 確認 2 | DNS を変えずに、CloudFront 経由で確かめる | — | — |

## 2-0. CDK の準備と設定値ファイル

準備（venv、`pip install`。`aws-cdk-lib` の取得は約 60 MB）は [cdk/python/README.md の準備](./cdk/python/README.md#準備)。設定値ファイルを作り、ステップ 2 の項目を書く。

```bash
cd cdk/python
cp config.example.yml config.yml
```

| 設定値 | 値 |
|---|---|
| `stack_name_prefix`、`aws_region`、`vpc_id`、`availability_zones`、`cloudfront_prefix_list_id` | 環境の値（プレフィックスリストの ID は下のコマンドで調べる） |
| `domain_name`、`origin_domain_name` | `app.example.com`、`origin.app.example.com` |
| `cloudfront_certificate_arn` | **ステップ 1 の `CertificateArn`** |
| `cloudfront_web_acl_arn` | 2-1 の後に書く（それまでは空） |
| `origin_hosted_zone_id`、`origin_elastic_ip` | ステージングだけ（2-2） |
| `waf_*` | 2-1 の表 |

```bash
aws ec2 describe-managed-prefix-lists --region ap-northeast-1 \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text
```

デプロイの仕方は 2 通りあり、どのスタックも同じ形で行う（詳しくは [cdk/python/README.md のデプロイ](./cdk/python/README.md#デプロイ)）。どちらも `cdk/python/` で、venv を有効にしてから流す。

| | 方法 1: CDK で直接反映する | 方法 2: CDK から CloudFormation のテンプレート（YAML）を出し、AWS CLI で反映する |
|---|---|---|
| 変更の中身を見る | `cdk diff` と、`cdk deploy` の確認の問い合わせ | 変更セット（`describe-change-set`） |
| 反映したテンプレート | 手元に残すことは考えない（`cdk.out/` は合成のたびに上書き） | `templates/<スタック名>.template.yml` に残る。`cfn-lint` にかけたり、人に渡したりできる |
| 秘密のヘッダーの値 | `--parameters <スタック名>:OriginVerifyHeaderValue=<値>` | `--parameter-overrides OriginVerifyHeaderValue=<値>` |

```bash
source .venv/bin/activate

# 方法 1: CDK で直接反映する
cdk diff   -c config=config.yml <スタック名>
cdk deploy -c config=config.yml <スタック名> --require-approval any-change [--parameters ...]

# 方法 2: CloudFormation のテンプレート（YAML）を出して、AWS CLI で反映する
mkdir -p templates
cdk synth -c config=config.yml <スタック名> > templates/<スタック名>.template.yml
aws cloudformation deploy --region <リージョン> --no-execute-changeset \
  --template-file templates/<スタック名>.template.yml --stack-name <スタック名> [--parameter-overrides ...]
aws cloudformation describe-change-set --region <リージョン> --stack-name <スタック名> --change-set-name <名前>
aws cloudformation execute-change-set --region <リージョン> --stack-name <スタック名> --change-set-name <名前>
```

- `cdk` の CLI を入れないときは、方法 2 で JSON のテンプレートを使う（`CDK_CONTEXT_JSON='{"config":"config.yml"}' CDK_OUTDIR=cdk.out .venv/bin/python app.py` で合成し、`--template-file cdk.out/<スタック名>.template.json` を渡す）
- 合成すると、ステップ 1 の CDK のスタック（`<prefix>-step1-certificate`）のテンプレートも出る。ステップ 1 を CloudFormation の YAML で済ませたなら使わない。`<スタック名>` を指定して流すので、ステップ 1 のスタックが反映し直されることはない

## 2-1. WAF の web ACL

国の絞り込み（既定は `JP` だけ）と例外の IP だけを持つ web ACL を作る。`/.well-known/acme-challenge/` だけはどの国からも通す（オリジンの証明書を HTTP-01 で更新し続けるため）。ルールの中身は [definitions.md の WAF](./definitions.md#ステップ-2-の-waf国の絞り込み)。AWS のマネージドルールとログは既定では入れない（入れるなら [options/waf-managed-rules.md](./options/waf-managed-rules.md)。[README の T10](./README.md#決めたこと)）。

| 決めること | 既定 | 内容 |
|---|---|---|
| 許可する国 | `JP` | 設定値 `waf_allowed_countries` |
| 例外の IP | なし | 設定値 `waf_exception_ipv4_addresses`・`waf_exception_ipv6_addresses`。海外から使う相手がいれば CIDR で足す |

2-0 のどちらかの方法で、`us-east-1` にデプロイする（パラメータはない。リージョンはスタックの定義に書いてある）。

```bash
# 方法 1: CDK で直接反映する
cdk diff   -c config=config.yml <prefix>-step2-waf
cdk deploy -c config=config.yml <prefix>-step2-waf --require-approval any-change

# 方法 2: CloudFormation のテンプレート（YAML）を出して、AWS CLI で反映する
cdk synth -c config=config.yml <prefix>-step2-waf > templates/<prefix>-step2-waf.template.yml
aws cloudformation deploy --region us-east-1 --no-execute-changeset \
  --template-file templates/<prefix>-step2-waf.template.yml --stack-name <prefix>-step2-waf
#   変更セットを確かめて反映する

# どちらの方法でも、出力の WebAclArn を見る
aws cloudformation describe-stacks --region us-east-1 --stack-name <prefix>-step2-waf \
  --query "Stacks[0].Outputs[?OutputKey=='WebAclArn'].OutputValue" --output text
```

出力の `WebAclArn` を、設定値の `cloudfront_web_acl_arn` に書く。

## 2-2. オリジンの名前

| 名前 | 種類 | 値 |
|---|---|---|
| `origin.app.example.com` | A | 稼働サーバーの Elastic IP |

| | ステージング（Route 53） | 本番（外部の DNS サービス） |
|---|---|---|
| 作り方 | 設定値 `origin_hosted_zone_id`・`origin_elastic_ip` を書くと、2-3 のスタックが作る | 2 つの設定値を空にして、外部の DNS サービスに手で足す。2-3 より前に足してよい |

オリジンの名前は、利用者のドメイン名と**別の名前**にする。同じ名前にすると CloudFront が自分自身に接続することになり、稼働サーバーへ届かない（CDK は合成のときに止める）。

## 2-3. CloudFront とオリジン用のセキュリティグループ

`cloudfront_web_acl_arn` を書いた設定値ファイルで、2-0 のどちらかの方法でデプロイする（どちらの方法も、流すたびに設定値ファイルから合成し直す）。秘密のヘッダーの値だけは、設定値ファイルに書かず、デプロイのときのパラメータで渡す（テンプレートに残さないため）。2 回目以降の更新では、渡さなければ前の値のまま（どちらの方法でも）。

```bash
# 方法 1: CDK で直接反映する
cdk diff   -c config=config.yml <prefix>-step2-cloudfront
cdk deploy -c config=config.yml <prefix>-step2-cloudfront --require-approval any-change \
  --parameters "<prefix>-step2-cloudfront:OriginVerifyHeaderValue=<準備の 4 で作った値>"

# 方法 2: CloudFormation のテンプレート（YAML）を出して、AWS CLI で反映する
cdk synth -c config=config.yml <prefix>-step2-cloudfront > templates/<prefix>-step2-cloudfront.template.yml
aws cloudformation deploy --region ap-northeast-1 --no-execute-changeset \
  --template-file templates/<prefix>-step2-cloudfront.template.yml \
  --stack-name <prefix>-step2-cloudfront \
  --parameter-overrides OriginVerifyHeaderValue=<準備の 4 で作った値>
#   変更セットを確かめて反映する
```

`cloudfront_certificate_arn` が空だと、このスタックは合成されない（標準エラーに「定義しなかったスタック」と出る。`cdk synth`・`cdk deploy` は、そのスタック名が見つからないとして止まる見込み）。

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
| WAF | 2-1 の web ACL | |
| IPv6 | 無効 | ステップ 3 の DNS のレコードは A だけでよい |

**注意**:

- オリジンの応答がタイムアウトしたとき、`GET`・`HEAD` は CloudFront が再試行する（既定で最大 3 回）。`GET` で状態を変える処理があれば、二重に実行されることがある。`POST` などは再試行しない
- 静的なファイルをキャッシュするなら、落ち着いてから `/assets/*` などのビヘイビアを足す

## 2-4. オリジン用のセキュリティグループを稼働サーバーに足す

2-3 の出力 `OriginSecurityGroupId`（CloudFront のプレフィックスリストから 443 番を許可するグループ）を、稼働サーバーに**足す**。`modify-instance-attribute --groups` は全部を置き換えるので、今のグループも並べる。**今の `0.0.0.0/0` などの許可は残す**（ステップ 3 の片付けで消す）。

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

# オリジンの名前
dig +short origin.app.example.com

# CloudFront 経由の接続
curl -sv --connect-to app.example.com:443:dxxxx.cloudfront.net:443 https://app.example.com/ -o /dev/null
```

| 確認 | 期待 |
|---|---|
| スタック | `<prefix>-step2-waf`・`<prefix>-step2-cloudfront` が `CREATE_COMPLETE`、ディストリビューションが `Deployed` |
| オリジンの名前 | `origin.app.example.com` が稼働サーバーの Elastic IP を返す |
| 利用者に見える証明書 | ステップ 1 の ACM の証明書（発行元が Amazon）で、名前の誤りがない |
| 応答の見出し | `Via` に `cloudfront.net`、`X-Cache` が `Miss from cloudfront` |
| ログイン、フォームの送信、ファイルのアップロード | 動く（ブラウザで確かめるなら、手元の `/etc/hosts` に CloudFront の IP を一時的に書く） |
| リダイレクト先 | `https://app.example.com/...`（`origin.app.example.com` が出ない） |
| `old_app_a` | `https://app.example.com/old_app_a/` が動く |
| 稼働サーバーの `access.log` の送り元 | 利用者（手元）の IP になる（CloudFront の IP ではない） |
| 502 が出るとき | オリジンの証明書（名前の不一致、期限切れ、中間証明書の不足）か、セキュリティグループ（2-4） |

WAF は、海外の確認用の端末から同じく `--connect-to` で確かめる。`--path-as-is` は、curl が `..` を手元で消さないようにするため。

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
2. `<prefix>-step2-cloudfront` を消す（`ap-northeast-1`）。ディストリビューションの無効化と削除に時間がかかる
3. `<prefix>-step2-waf` を消す（`us-east-1`。CloudFront から外れた後でないと消せない）
4. 本番で手で足した `origin.app.example.com` を消す

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-13）。CDK の CLI の参考は [cdk/python/README.md の参考](./cdk/python/README.md#参考)。WAF の参考は [definitions.md の参考](./definitions.md#参考)。

- [Require HTTPS between CloudFront and your custom origin](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-https-cloudfront-to-custom-origin.html)
- [Origin settings（Origin domain は公開の DNS 名）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesOrigin.html)
- [Cache behavior settings](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesCacheBehavior.html)
- [Use managed cache policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html)
- [Use managed origin request policies（AllViewer）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html)
- [Add custom headers to origin requests](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/add-origin-custom-headers.html)
- [Locations and IP address ranges of CloudFront edge servers](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html)
- [AWS-managed prefix lists（weight）](https://docs.aws.amazon.com/vpc/latest/userguide/working-with-aws-managed-prefix-lists.html)
- [Geographic match rule statement（地理的制限で止めた要求は WAF に届かない）](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-geo-match.html)（2026-11-11）
