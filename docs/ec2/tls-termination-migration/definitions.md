# 3 つの構成の ALB・CloudFront の定義

> 位置付け: [3 つの構成](./README.md)の ALB と CloudFront を、CloudFormation の YAML と CDK（Python）で定義したもの。同じ構成を 2 通りの書き方で置いている。
>
> 状態: **骨組み（AWS へのデプロイはしていない）**。YAML と CDK の出力は `cfn-lint` を通した。CDK は `aws-cdk-lib` 2.275.0 で合成し、`restrict_to_cloudfront` の両方の値と WAF を付けた場合を確かめた。合成の結果は YAML と内容を突き合わせた（下の「YAML と CDK の違い」）。CloudFront 用の WAF の web ACL（2026-11-11 に追加）も、`cfn-lint` と合成で確かめた。
>
> 作成日: 2026-11-10

## 構成

| 構成 | CloudFormation | CDK のスタック |
|---|---|---|
| ALB → EC2 | `cloudformation/alb-to-ec2.yml` | `<prefix>-alb-to-ec2` |
| CloudFront → EC2 | `cloudformation/cloudfront-to-ec2.yml` | `<prefix>-cloudfront-to-ec2` |
| CloudFront → ALB → EC2 | `cloudformation/cloudfront-alb-to-ec2.yml` | `<prefix>-cloudfront-alb-to-ec2` |
| CloudFront → EC2（[外部のドメイン名を変えない場合](./cloudfront-to-ec2-same-domain.md)） | `cloudformation/cloudfront-to-ec2-same-domain.yml` | `<prefix>-cloudfront-to-ec2-same-domain` |
| 上の構成の外向きの ACM の証明書（`us-east-1`） | `cloudformation/cloudfront-to-ec2-same-domain-certificate.yml` | `<prefix>-cloudfront-certificate` |
| CloudFront 用の WAF の web ACL とログ（`us-east-1`。CloudFront → EC2 の防御） | `cloudformation/cloudfront-waf.yml` | `<prefix>-cloudfront-waf` |

```
cdk/python/
  app.py                       設定値ファイルから 3 つのスタックを定義する
  config.example.yml           設定値の例
  tls_termination_cdk/
    configuration.py           設定値の読み込み
    stacks/
      common.py                スタックの土台、CloudFront のディストリビューション、秘密のヘッダーのパラメータ
      alb.py                   ALB・ターゲットグループ・リスナー・セキュリティグループ（2 つの構成で共用）
      alb_to_ec2.py
      cloudfront_to_ec2.py
      cloudfront_to_ec2_same_domain.py
      cloudfront_certificate.py
      cloudfront_waf.py
      cloudfront_alb_to_ec2.py
```

CDK は L2 で書いているので、論理 ID は CloudFormation の YAML と違う。YAML でデプロイしたスタックを CDK の出力で更新しない。逆も同じ。

## 定義に含めるもの

| 種類 | リソース |
|---|---|
| ALB | ロードバランサー、ターゲットグループ（`new_app_b`: 8080 番、`old_app_a`: 80 番）、HTTPS・HTTP のリスナー、パスとヘッダーのルール |
| CloudFront | ディストリビューション（HTTPS only、`CachingDisabled`、`AllViewer`、秘密のヘッダー）。CloudFront → EC2 の 2 つの定義は、地理的制限の設定も持つが、既定は使わない（国の絞り込みは WAF） |
| セキュリティグループ | ALB 用、CloudFront → EC2 のオリジン用、既存のインスタンスのグループへの許可の追加 |
| WAF | 構成の定義は**関連付けだけ**（web ACL の ARN を渡したとき）。CloudFront 用の web ACL（国の絞り込み、例外の IP、マネージドルール、ログ）は `cloudfront-waf.yml`（下の「国の絞り込み（WAF）」） |

## 定義に含めないもの

| もの | 理由・行うこと |
|---|---|
| ACM の証明書 | CloudFront 用は `us-east-1` に要り、スタックのリージョンと分かれる。先に作って ARN を渡す（外部のドメイン名を変えない構成は、`us-east-1` の証明書のスタックを別に用意している） |
| ALB 用の WAF の web ACL | 中身のルールは要件次第。先に作って ARN を渡す（CloudFront 用は `cloudfront-waf.yml` を用意した） |
| DNS のレコード | 切り替えの時点を担当者が決めるため。`origin.<ドメイン>` と本番の名前は別に用意する |
| インスタンスへのセキュリティグループの付け替え | CloudFront → EC2 の出力 `OriginSecurityGroupId` を、既存のグループに**足して**付ける（`modify-instance-attribute --groups` は全部を置き換えるので、既存のグループも並べる） |
| 静的なファイルのキャッシュ | 使うと決まってから足す |
| CloudFront → ALB → EC2 の地理的制限 | 国で絞る方法を決めてから足す（CloudFront → EC2 だけ先に入れた） |

## 国の絞り込み（WAF）

CloudFront → EC2 では、WAF で防御する（2026-11-11 に決めた）。国で絞り、特定の IP を例外にでき、AWS のマネージドルールを入れ、ログを残す。EC2 の Let's Encrypt の証明書を、CloudFront 経由の HTTP-01 で更新し続けるため、確認のパスだけはどの国からも通す。

| ルール | 優先順位 | 条件 | 動作 |
|---|---|---|---|
| `AllowAcmeChallenge` | 0 | パスが `/.well-known/acme-challenge/` で始まる。比べる前に `URL_DECODE`、`NORMALIZE_PATH` の順で変換する | 通す（以降のルールは見ない） |
| `BlockOutsideAllowedCountries` | 1 | 送り元の国が許可する国（既定 `JP`）になく、**かつ**例外の IP の一覧（IPv4・IPv6）にもない | 止める（CloudFront が 403 を返す） |
| `AWSManagedRulesAmazonIpReputationList` | 2 | Amazon の脅威情報で悪いとされた IP | 最初は記録だけ（下の「マネージドルール」） |
| `AWSManagedRulesCommonRuleSet` | 3 | よくある攻撃（XSS、パスの移動、大きすぎる要求など） | 同上 |
| `AWSManagedRulesKnownBadInputsRuleSet` | 4 | 既知の悪い入力（Log4j など） | 同上 |
| 既定の動作 | — | どれにも当たらない | 通す |

国の絞り込みをマネージドルールより先にしているのは、マネージドルールのログを、許可する国と例外の IP からの要求だけにして、誤検知を見やすくするためである。例外の IP もマネージドルールは通る。

- **変換の理由**: `/.well-known/acme-challenge/../../admin` や `%2e%2e` のように、例外のパスで始まって外へ出る要求を、例外に当てないため。`NORMALIZE_PATH` は重複したスラッシュ、`.`、`..` を取り除く
- **CloudFront の地理的制限は使わない**: 地理的制限で止めた要求は WAF に届かないので、パスの例外を作れない。CloudFront → EC2 の 2 つの定義のパラメータ `GeoRestrictionType` の既定を `none` に変えた（CDK は `geo_restriction_countries` の既定を空に変えた）。`whitelist` にすると、HTTP-01 の更新が止まる
- **国の判定**: 送り元の IP アドレス（CloudFront に接続した利用者）で行う。`X-Forwarded-For` は使わない（利用者が書き換えられるため）
- **料金**: web ACL 1 つで月 $5、ルール 1 つで月 $1、100 万リクエストごとに $0.60（[README](./README.md#waf-を置ける場所)。2026-11-09 確認）。ルール 2 つとマネージドルールグループ 3 つで、ルールを 5 つと数えれば月 $10。マネージドルールグループの数え方と、この 3 つに追加の料金がないことは、料金のページで確かめていない。ほかに CloudWatch Logs の料金がかかる
- **キャパシティ（WCU）**: マネージドルールグループが 25・700・200、自分で書いたルールが約 25 で、合計は約 950。web ACL の上限 1,500 に収まる
- **httpd**: 443 番の VirtualHost に確認のパスの設定が要る（[証明書の更新](./cloudfront-to-ec2-httpd.md#証明書の更新)）
- `CloudFrontWebAclArn` は空でもデプロイできる（その間は国で絞らず、マネージドルールも効かない）。一旦、任意のままにする（2026-11-11。必須にするかは後で決め直す）。本番で空にしない

| CloudFormation のパラメータ | CDK の設定値 | 内容 |
|---|---|---|
| `AllowedCountries` | `waf_allowed_countries` | 許可する国（ISO 3166-1 alpha-2。既定 `JP`。CDK は空だとエラー） |
| `ExceptionIpv4Addresses`、`ExceptionIpv6Addresses` | `waf_exception_ipv4_addresses`、`waf_exception_ipv6_addresses` | 許可する国の外から通す IP（CIDR。例 `192.0.2.44/32`）。既定は空。一覧は空でも作っておくので、例外を足すときは値を変えて更新するだけでよい |
| `ManagedRulesMode` | `waf_managed_rules_mode` | `count`（既定。記録だけ）か `block` |
| `LogRetentionInDays` | `waf_log_retention_days` | ログを残す日数（既定 30） |

### マネージドルール

最初は `count` で入れ、ログで誤検知がないことを確かめてから `block` に切り替える（2026-11-11 に決めた）。

- `count` の間は、ルールグループの中のルールを 1 つずつ Count に上書きする（`RuleActionOverrides`）。ルールグループ全体を Count にする方法（`OverrideAction: Count`）は、AWS のドキュメントで試験に向かないとされているので使わない（最初に当たったルールだけが数えられ、ほかのルールが当たるかは分からないため）
- 上書きするルールの名前は、AWS のドキュメントの一覧から写した（2026-11-11）。ルールグループの版が上がってルールが増えると、増えたルールは上書きされず、`count` の間も止める。版が上がったら一覧を見直す
- 切り替える前に、ログで Count になった要求のラベル（`awswaf:managed:aws:...`）を見る。特に `SizeRestrictions_BODY` は 8 KB を超える本文を止めるので、フォームの送信やファイルのアップロードで当たる見込みが高い。当たるルールがあれば、そのルールだけ Count のまま残して `block` にする（テンプレートの、そのルールの上書きを残す形に直す）

### ログ

`us-east-1` の CloudWatch Logs のロググループ `aws-waf-logs-<スタック名>` に送り、30 日残す（2026-11-11 に決めた）。名前は `aws-waf-logs-` で始め、web ACL と同じリージョンとアカウントに置く決まりである。ロググループの書き込みの許可（リソースポリシー）は、ログの設定を作るときに WAF が付ける。

- ログには要求の見出し（ヘッダー）が入る見込みで、Cookie（セッション）が残るかもしれない。どの項目が残るかは、実際のログで確かめる。残したくない項目があれば、ログの設定の `RedactedFields` か、web ACL のデータ保護の設定で消す（AWS のドキュメントでは、`RedactedFields` で消せるのは `UriPath`、`QueryString`、`SingleHeader`、`Method` だけ）
- ログを読める人を、CloudWatch Logs の権限で絞る

### デプロイ

```bash
# 1. web ACL（us-east-1）
aws cloudformation deploy --region us-east-1 \
  --template-file cloudformation/cloudfront-waf.yml \
  --stack-name <スタック名>-waf

# 2. web ACL の ARN を確かめる
aws cloudformation describe-stacks --region us-east-1 --stack-name <スタック名>-waf \
  --query "Stacks[0].Outputs[?OutputKey=='WebAclArn'].OutputValue" --output text

# 3. CloudFront のスタック（ap-northeast-1）に CloudFrontWebAclArn=<2 の ARN> を足して反映する
```

CDK では、`<prefix>-cloudfront-waf` を合成・デプロイし、出力の ARN を設定値の `cloudfront_web_acl_arn` に書いてから、CloudFront のスタックを合成する。

### 確かめ方（AWS では未確認）

海外のリージョン（例: `us-west-2`）の EC2 か Lambda と、国内から流す。`--path-as-is` は、curl が `..` を手元で消さないようにするため。

| 送り元 | 要求 | 期待 |
|---|---|---|
| 海外 | `curl -sI https://app.example.com/` | 403（WAF） |
| 海外 | `curl -sI https://app.example.com/.well-known/acme-challenge/test` | httpd の 404（WAF を通った） |
| 海外 | `curl -sI --path-as-is https://app.example.com/.well-known/acme-challenge/../../` | 403 |
| 海外 | `curl -sI --path-as-is https://app.example.com/.well-known/acme-challenge/%2e%2e/%2e%2e/` | 403 |
| 国内 | `curl -sI https://app.example.com/` | アプリの応答 |
| 稼働サーバー | `sudo certbot renew --dry-run` | 成功 |

止めた件数と例は、web ACL の CloudWatch のメトリクス、サンプルのリクエスト（`SampledRequestsEnabled`）、ログで見られる。例外の IP は、一覧に入れた IP から `curl -sI https://app.example.com/` を流してアプリの応答になることで確かめる。

httpd の設定は別に要る（[ALB](./alb-to-ec2.md#3-httpd-に-http-の-virtualhost-を足す)、[CloudFront](./cloudfront-to-ec2-httpd.md)）。

## 使い方

CloudFront のプレフィックスリストの ID を調べる。

```bash
aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text
```

### CloudFormation

変更セットを作って、確認してから反映する。

```bash
aws cloudformation deploy --no-execute-changeset \
  --template-file cloudformation/alb-to-ec2.yml \
  --stack-name <スタック名> \
  --parameter-overrides VpcId=<VPC> SubnetIds=<サブネット 1>,<サブネット 2> \
    InstanceId=<インスタンス ID> InstanceSecurityGroupId=<グループ> \
    AlbCertificateArn=<証明書の ARN>
```

### CDK（Python）

準備・合成・デプロイ・撤去のコマンドの一覧は [cdk/python/README.md](./cdk/python/README.md)。

`aws-cdk-lib` の取得（約 60 MB）と Node.js が要る。合成だけなら `aws-cdk` の CLI は要らない。

```bash
cd cdk/python
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp config.example.yml config.yml   # 環境の値に直す
CDK_CONTEXT_JSON='{"config":"config.yml"}' CDK_OUTDIR=cdk.out .venv/bin/python app.py
```

`cdk.out/<スタック名>.template.json` を、上の `aws cloudformation deploy` で反映する（`cdk bootstrap` は不要）。Node.js 26 では jsii が未検証の警告を出す（合成は成功した）。対応版は 22 と 24。

### CloudFront → EC2（外部のドメイン名を変えない場合）

`ap-northeast-1` を前提にする。CloudFront の外向きの証明書は ACM で管理する。CloudFront が使う ACM の証明書は `us-east-1` に置く決まりなので、証明書だけ別のスタックにしている。

| スタック | リージョン | 内容 |
|---|---|---|
| `cloudfront-to-ec2-same-domain-certificate.yml` | `us-east-1` | `app.example.com` の ACM の証明書 |
| `cloudfront-waf.yml` | `us-east-1` | WAF の web ACL（[国の絞り込み](#国の絞り込みwaf)） |
| `cloudfront-to-ec2-same-domain.yml` | `ap-northeast-1` | CloudFront、オリジン用のセキュリティグループ、`origin.app.example.com` の Route 53 のレコード（任意） |

| パラメータ | 内容 |
|---|---|
| 証明書のスタックの `HostedZoneId` | `app.example.com` のホストゾーンが同じアカウントの Route 53 にあるなら指定する。検証用のレコードが自動で作られる。空にすると、ACM が示す CNAME を DNS に足すまで、スタックは `CREATE_IN_PROGRESS` のまま待つ。ステージングは Route 53 なので指定する。本番は外部の DNS サービスなので空にする（[外部の DNS サービスで管理しているドメインの手順](./external-dns-certificate.md)） |
| `OriginHostedZoneId`、`OriginElasticIp` | `origin.app.example.com` のレコードもこのスタックで作るときに指定する。別の DNS で管理するなら空にして、手で作る（本番はこちら） |

`app.example.com` のレコードは定義に含めない。既にあるレコードで、切り替えの時点も担当者が決めるため。`OriginDomainName` と `DomainName` が同じだと EC2 へ届かないので、デプロイのときに止まるようにしている（CDK は合成のとき）。

```bash
# 1. 証明書（us-east-1）
aws cloudformation deploy --region us-east-1 \
  --template-file cloudformation/cloudfront-to-ec2-same-domain-certificate.yml \
  --stack-name <スタック名>-certificate \
  --parameter-overrides DomainName=app.example.com HostedZoneId=<ホストゾーン ID>

# 2. 証明書の ARN を確かめる
aws cloudformation describe-stacks --region us-east-1 --stack-name <スタック名>-certificate \
  --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" --output text

# 3. WAF の web ACL（us-east-1）を作り、ARN を確かめる（上の「国の絞り込み（WAF）」の 1・2）

# 4. CloudFront など（ap-northeast-1）。変更セットを確認してから反映する
aws cloudformation deploy --region ap-northeast-1 --no-execute-changeset \
  --template-file cloudformation/cloudfront-to-ec2-same-domain.yml \
  --stack-name <スタック名> \
  --parameter-overrides VpcId=<VPC> CloudFrontPrefixListId=<pl-...> \
    DomainName=app.example.com OriginDomainName=origin.app.example.com \
    CloudFrontCertificateArn=<2 の ARN> CloudFrontWebAclArn=<3 の ARN> \
    OriginVerifyHeaderValue=<秘密の値> \
    OriginHostedZoneId=<ホストゾーン ID> OriginElasticIp=<Elastic IP>
```

CloudFront のプレフィックスリストの ID は、上の `describe-managed-prefix-lists` に `--region ap-northeast-1` を付けて調べる。

CDK では、`<prefix>-cloudfront-certificate` と `<prefix>-cloudfront-waf` を先に合成・デプロイし、出力の ARN を設定値の `cloudfront_certificate_arn` と `cloudfront_web_acl_arn` に書いてから、`<prefix>-cloudfront-to-ec2-same-domain` を合成する。

### 秘密のヘッダーの値

CloudFront を使う 2 つの構成は、`OriginVerifyHeaderValue` を**デプロイのときのパラメータ**で渡す（32 文字以上）。`NoEcho` にしているのでテンプレートと `describe-stacks` には出ないが、CloudFront の設定と ALB のルールを読める人には見える。

```bash
openssl rand -hex 32
```

### CloudFront → ALB → EC2 の 2 段階

1. `RestrictToCloudFront=false`（CDK は `restrict_to_cloudfront: false`）でデプロイする。ALB には直接も CloudFront からも届く。
2. DNS を CloudFront へ向け、元の TTL が過ぎるまで待つ。
3. `RestrictToCloudFront=true` で更新する。セキュリティグループが CloudFront のプレフィックスリストの 443 番だけになり、ヘッダーのない要求は 403 になる。

## YAML と CDK の違い

合成の結果を YAML と項目ごとに比べた（セキュリティグループ、ターゲットグループ、リスナー、ルール、ディストリビューション）。違いは次のとおりで、動作は同じ見込み。

| 項目 | YAML | CDK の出力 |
|---|---|---|
| プレフィックスリストからの許可 | セキュリティグループの中に書く | 別のリソース（`AWS::EC2::SecurityGroupIngress`） |
| CloudFront → EC2 のオリジン用のグループの外向き | 省略（既定の全許可） | 全許可を明示 |
| ALB の `deletion_protection.enabled` | 省略（既定の `false`） | `false` を明示 |
| オリジンの `HTTPSPort` | `443` を明示 | 省略（既定の 443） |
| `RestrictToCloudFront` | パラメータで切り替える | 設定値で切り替える（合成し直す） |
| ACM の証明書の `Name` タグ | なし | CDK が付ける |
| 論理 ID | 短い名前 | CDK が生成する名前 |

CDK の ALB のセキュリティグループの外向きは、L2 の `add_egress_rule` を使わず、L1 のプロパティで直接書いている。理由は `tls_termination_cdk/stacks/alb.py` のコメントのとおり。

## 確かめること

| 項目 | 内容 |
|---|---|
| AWS での検証 | 変更セットの作成と、実際のデプロイ。`cfn-lint` はプロパティの形を見るだけで、ID の実在や権限は見ない |
| 既存のセキュリティグループへの許可の追加 | スタックを消すと、足した許可も消える |

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09、2026-11-10）のは、[README](./README.md#参考) と各手順の「参考」、および次のページ。

- [AWS::EC2::SecurityGroup（既定の外向きの規則）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-securitygroup.html)
- [AWS::EC2::SecurityGroupEgress](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-securitygroupegress.html)
- [AWS::CertificateManager::Certificate（DNS 検証）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-certificatemanager-certificate.html)

WAF は 2026-11-11 に照らし合わせた。

- [AWS::WAFv2::WebACL（CLOUDFRONT は us-east-1 に作る、GetAtt の Arn）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-wafv2-webacl.html)
- [Geographic match rule statement（CloudFront の地理的制限で止めた要求は WAF に届かない、送り元の IP で判定）](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-geo-match.html)
- [String match rule statement（Starts with、変換は並べた順に行う）](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-string-match.html)
- [Using text transformations（URL_DECODE、NORMALIZE_PATH）](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-transformation.html)
- [AWS::WAFv2::IPSet（Addresses は空の配列でよい、CIDR で書く）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-wafv2-ipset.html)
- [Baseline rule groups（CommonRuleSet と KnownBadInputsRuleSet の名前、WCU、ルールの一覧）](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-baseline.html)
- [IP reputation rule groups（AmazonIpReputationList）](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-ip-rep.html)
- [Overriding rule group actions（試験にはルールごとの Count の上書きを使う）](https://docs.aws.amazon.com/waf/latest/developerguide/web-acl-rule-group-override-options.html)
- [AWS::WAFv2::LoggingConfiguration（送り先は aws-waf-logs- で始める、RedactedFields）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-wafv2-loggingconfiguration.html)
- [Sending web ACL traffic logs to CloudWatch Logs（同じリージョンとアカウント）](https://docs.aws.amazon.com/waf/latest/developerguide/logging-cw-logs.html)
- [AWS::Logs::LogGroup（GetAtt の Arn は末尾に :* が付く）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-logs-loggroup.html)
