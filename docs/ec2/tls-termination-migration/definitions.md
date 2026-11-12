# 定義（CloudFormation の YAML と CDK）

> 位置付け: B. CloudFront → EC2 への移行の 3 つのステップのうち、ステップ 1・2 で使う定義の中身。同じ内容を CloudFormation の YAML（`cloudformation/`）と CDK（Python。`cdk/python/`）の 2 通りで置いている。**手順で使うのは、ステップ 1 が CloudFormation の YAML、ステップ 2 が CDK**（[README の T9](./README.md#決めたこと)）。ステップ 3 はシェルスクリプト `scripts/step3-dns-switch.sh`。CDK のコマンドは [cdk/python/README.md](./cdk/python/README.md)。手順の全体は [README](./README.md#3-つのステップ)。
>
> 状態: **骨組み（AWS へのデプロイはしていない）**。YAML と CDK の出力は `cfn-lint` 1.60.0 を警告なしで通した（2026-11-12）。CDK は `aws-cdk-lib` 2.275.0 で合成し、3 つのステップの形に組み替える前と後で、リソースの中身が同じであることを確かめた（違いはスタック名から決まる名前と説明だけ。2026-11-12）。合成の結果は YAML と内容を突き合わせた（下の「YAML と CDK の違い」）。
>
> 作成日: 2026-11-10（3 つのステップの順に並べ直した: 2026-11-12）

## 用語

[README の用語](./README.md#用語)と同じ。スタック名の `<prefix>` は、環境ごとの頭（例 `myapp-production`。CDK は設定値の `stack_name_prefix`）。

## ステップと定義の対応

| ステップ | 定義（CloudFormation） | CDK のスタック | 手順で使う | リージョン | 作るもの |
|---|---|---|---|---|---|
| 1 | `cloudformation/step1-certificate.yml` | `<prefix>-step1-certificate` | **CloudFormation** | `us-east-1` | CloudFront の証明書（ACM で作成する場合。登録する場合は使わない） |
| 2 | `cloudformation/step2-waf.yml` | `<prefix>-step2-waf` | **CDK** | `us-east-1` | CloudFront 用の WAF の web ACL、例外の IP の一覧、ログ |
| 2 | `cloudformation/step2-cloudfront.yml` | `<prefix>-step2-cloudfront` | **CDK** | `ap-northeast-1` | CloudFront、オリジン用のセキュリティグループ、オリジンの名前の Route 53 のレコード（任意） |
| 3 | なし | なし | **シェルスクリプト** `scripts/step3-dns-switch.sh`（[比べた表](./step3-dns-switch.md#シェルスクリプトにした理由)） | — | 利用者のドメイン名の A レコードの置き換え（Route 53） |

ステップの順にデプロイする。後のステップは、前のステップの出力（ARN）を受け取る（ステップ 1 の `CertificateArn` は CDK の設定値 `cloudfront_certificate_arn` に書く。スタックの Export は使わない）。手順で使わない方の書き方（ステップ 1 の CDK、ステップ 2 の YAML）も、同じ内容として残している。

```mermaid
%%{init: {"themeVariables": {"fontSize": "16px"}}}%%
flowchart TD
  S1["ステップ 1: step1-certificate.yml（CloudFormation。us-east-1）<br/>出力 CertificateArn"]
  W["ステップ 2: （prefix）-step2-waf（CDK。us-east-1）<br/>出力 WebAclArn"]
  CF["ステップ 2: （prefix）-step2-cloudfront（CDK。ap-northeast-1）<br/>出力 DistributionDomainName、OriginSecurityGroupId"]
  S3["ステップ 3（scripts/step3-dns-switch.sh）<br/>app.example.com → DistributionDomainName"]
  S1 -- "設定値 cloudfront_certificate_arn" --> CF
  W -- "設定値 cloudfront_web_acl_arn" --> CF
  CF -- "DistributionDomainName" --> S3
```

### オプション（採用しなかった構成）

| 構成 | 定義（CloudFormation） | CDK のスタック（`option_stacks` で指定したときだけ） | 手順 |
|---|---|---|---|
| A. ALB → EC2 | `cloudformation/options/alb-to-ec2.yml` | `<prefix>-option-alb-to-ec2` | [options/alb-to-ec2.md](./options/alb-to-ec2.md) |
| C. CloudFront → ALB → EC2 | `cloudformation/options/cloudfront-alb-to-ec2.yml` | `<prefix>-option-cloudfront-alb-to-ec2` | [options/cloudfront-alb-to-ec2.md](./options/cloudfront-alb-to-ec2.md) |

前の版にあった `cloudfront-to-ec2.yml`（利用者のドメイン名を変えることも想定した B）は、`step2-cloudfront.yml` から Route 53 のレコードと名前の確認を除いただけの同じ定義だったので、`step2-cloudfront.yml` に一本化した（2026-11-12）。

## ファイル

```
cloudformation/
  step1-certificate.yml        ステップ 1（手順で使う）
  step2-waf.yml                ステップ 2 の YAML 版（手順では CDK を使う）
  step2-cloudfront.yml         ステップ 2 の YAML 版（同上）
  options/                     オプション（A・C）
scripts/
  step3-dns-switch.sh          ステップ 3（Route 53 の A レコードの置き換えと戻し）
cdk/python/
  app.py                       設定値ファイルからスタックを定義する
  README.md                    使い方と実行コマンド
  config.example.yml           設定値の例
  tls_termination_cdk/
    configuration.py           設定値の読み込みと検証
    stacks/
      __init__.py              どのスタックを定義するか（本線の 3 つと、option_stacks で指定したオプション）
      common.py                スタックの土台、CloudFront のディストリビューション、秘密のヘッダーのパラメータ、オリジン用のセキュリティグループ
      step1_certificate.py
      step2_waf.py
      step2_cloudfront.py
      options/                 オプション（A・C と、2 つで共用する ALB の部分 alb.py）
```

CDK は L2 で書いているので、論理 ID は CloudFormation の YAML と違う。YAML でデプロイしたスタックを CDK の出力で更新しない。逆も同じ。

## 定義に含めるもの・含めないもの

| もの | 含めるか | 内容・理由 |
|---|---|---|
| CloudFront の証明書 | ステップ 1 に含める | ACM で作成する場合だけ。既存の証明書の登録は CloudFormation が対応していないので、AWS CLI で行う（[ステップ 1 の 1-B](./step1-acm-certificate.md#1-b-既存の証明書を登録するオプション)） |
| WAF の web ACL | ステップ 2 に含める | 国の絞り込み、例外の IP、マネージドルール、ログ（下の「ステップ 2 の WAF」） |
| CloudFront | ステップ 2 に含める | HTTPS only、`CachingDisabled`、`AllViewer`、秘密のヘッダー。地理的制限の設定も持つが、既定は使わない |
| オリジン用のセキュリティグループ | ステップ 2 に含める | CloudFront のプレフィックスリストから 443 番を許可する |
| オリジンの名前の DNS のレコード | ステップ 2 に任意で含める | Route 53（ステージング）なら `OriginHostedZoneId`・`OriginElasticIp` で作る。外部の DNS サービス（本番）なら空にして手で足す |
| 利用者のドメイン名の DNS のレコード | **含めない** | 今もあるレコードで、ステップ 3 で AWS CLI で変える（[README の T8](./README.md#決めたこと)） |
| 稼働サーバーへのセキュリティグループの付け替え | **含めない** | 出力 `OriginSecurityGroupId` を、既存のグループに**足して**付ける（[ステップ 2 の 2-4](./step2-cloudfront.md#2-4-オリジン用のセキュリティグループを稼働サーバーに足す)） |
| 静的なファイルのキャッシュ | 含めない | 使うと決まってから足す |

## ステップ 1 の証明書

| パラメータ（CloudFormation） | CDK の設定値 | 内容 |
|---|---|---|
| `DomainName` | `domain_name` | 利用者のドメイン名（`app.example.com`） |
| `HostedZoneId` | `certificate_hosted_zone_id` | `app.example.com` のホストゾーンが同じアカウントの Route 53 にあるなら指定する（ステージング）。検証用のレコードが自動で作られる。空にすると、ACM が示す CNAME を DNS に足すまで、スタックは `CREATE_IN_PROGRESS` のまま待つ（本番） |

`us-east-1` 以外でデプロイすると、テンプレートの規則（`Rules`）で止まる。出力は `CertificateArn`。

## ステップ 2 の WAF（国の絞り込み）

CloudFront → EC2 では、WAF で防御する（2026-11-11 に決めた）。国で絞り、特定の IP を例外にでき、AWS のマネージドルールを入れ、ログを残す。オリジンの証明書（Let's Encrypt）を CloudFront 経由の HTTP-01 で更新し続けるため、確認のパスだけはどの国からも通す。

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
- **CloudFront の地理的制限は使わない**: 地理的制限で止めた要求は WAF に届かないので、パスの例外を作れない。`step2-cloudfront.yml` のパラメータ `GeoRestrictionType` の既定は `none`（CDK は `geo_restriction_countries` の既定が空）。`whitelist` にすると、HTTP-01 の更新が止まる
- **国の判定**: 送り元の IP アドレス（CloudFront に接続した利用者）で行う。`X-Forwarded-For` は使わない（利用者が書き換えられるため）
- **料金**: web ACL 1 つで月 $5、ルール 1 つで月 $1、100 万リクエストごとに $0.60（2026-11-09 確認）。ルール 2 つとマネージドルールグループ 3 つで、ルールを 5 つと数えれば月 $10。マネージドルールグループの数え方と、この 3 つに追加の料金がないことは、料金のページで確かめていない。ほかに CloudWatch Logs の料金がかかる
- **キャパシティ（WCU）**: マネージドルールグループが 25・700・200、自分で書いたルールが約 25 で、合計は約 950。web ACL の上限 1,500 に収まる
- **httpd**: 443 番の VirtualHost に確認のパスの設定が要る（[証明書の更新](./cloudfront-to-ec2-httpd.md#証明書の更新)。[準備](./step0-preparation.md#3-稼働サーバーの-httpd-の設定)で入れる）
- `CloudFrontWebAclArn` は空でもデプロイできる（その間は国で絞らず、マネージドルールも効かない）。一旦、任意のままにする（2026-11-11。必須にするかは後で決め直す）。**本番で空にしない**

| パラメータ（CloudFormation） | CDK の設定値 | 内容 |
|---|---|---|
| `AllowedCountries` | `waf_allowed_countries` | 許可する国（ISO 3166-1 alpha-2。既定 `JP`。CDK は空だとエラー） |
| `ExceptionIpv4Addresses`、`ExceptionIpv6Addresses` | `waf_exception_ipv4_addresses`、`waf_exception_ipv6_addresses` | 許可する国の外から通す IP（CIDR。例 `192.0.2.44/32`）。既定は空。一覧は空でも作っておくので、例外を足すときは値を変えて更新するだけでよい |
| `ManagedRulesMode` | `waf_managed_rules_mode` | `count`（既定。記録だけ）か `block` |
| `LogRetentionInDays` | `waf_log_retention_days` | ログを残す日数（既定 30） |

出力は `WebAclArn`（`step2-cloudfront.yml` の `CloudFrontWebAclArn` に渡す）と `WebAclLogGroupName`。

### マネージドルール

最初は `count` で入れ、ログで誤検知がないことを確かめてから `block` に切り替える（2026-11-11 に決めた。切り替えは [ステップ 3 の片付け](./step3-dns-switch.md#3-5-片付け)の後）。

- `count` の間は、ルールグループの中のルールを 1 つずつ Count に上書きする（`RuleActionOverrides`）。ルールグループ全体を Count にする方法（`OverrideAction: Count`）は、AWS のドキュメントで試験に向かないとされているので使わない（最初に当たったルールだけが数えられ、ほかのルールが当たるかは分からないため）
- 上書きするルールの名前は、AWS のドキュメントの一覧から写した（2026-11-11）。ルールグループの版が上がってルールが増えると、増えたルールは上書きされず、`count` の間も止める。版が上がったら一覧を見直す
- 切り替える前に、ログで Count になった要求のラベル（`awswaf:managed:aws:...`）を見る。特に `SizeRestrictions_BODY` は 8 KB を超える本文を止めるので、フォームの送信やファイルのアップロードで当たる見込みが高い。当たるルールがあれば、そのルールだけ Count のまま残して `block` にする（テンプレートの、そのルールの上書きを残す形に直す）

### ログ

`us-east-1` の CloudWatch Logs のロググループ `aws-waf-logs-<スタック名>`（例 `aws-waf-logs-<prefix>-step2-waf`）に送り、30 日残す（2026-11-11 に決めた）。名前は `aws-waf-logs-` で始め、web ACL と同じリージョンとアカウントに置く決まりである。ロググループの書き込みの許可（リソースポリシー）は、ログの設定を作るときに WAF が付ける。

- ログには要求の見出し（ヘッダー）が入る見込みで、Cookie（セッション）が残るかもしれない。どの項目が残るかは、実際のログで確かめる。残したくない項目があれば、ログの設定の `RedactedFields` か、web ACL のデータ保護の設定で消す（AWS のドキュメントでは、`RedactedFields` で消せるのは `UriPath`、`QueryString`、`SingleHeader`、`Method` だけ）
- ログを読める人を、CloudWatch Logs の権限で絞る

確かめ方は [ステップ 2 の確認 2](./step2-cloudfront.md#確認-2ステップ-3-へ進む条件)。

## ステップ 2 の CloudFront

| パラメータ（CloudFormation） | CDK の設定値 | 内容 |
|---|---|---|
| `VpcId` | `vpc_id` | オリジン用のセキュリティグループを作る VPC（稼働サーバーの VPC） |
| `CloudFrontPrefixListId` | `cloudfront_prefix_list_id` | `com.amazonaws.global.cloudfront.origin-facing` の ID（リージョンごとに違う） |
| `DomainName` | `domain_name` | 利用者のドメイン名。代替ドメイン名になる |
| `OriginDomainName` | `origin_domain_name` | オリジンの名前。`DomainName` と同じだとデプロイのとき（CDK は合成のとき）に止まる |
| `CloudFrontCertificateArn` | `cloudfront_certificate_arn` | ステップ 1 の `CertificateArn`。CDK は空の間このスタックを合成しない |
| `CloudFrontWebAclArn` | `cloudfront_web_acl_arn` | ステップ 2 の WAF の `WebAclArn` |
| `OriginVerifyHeaderValue` | なし（デプロイのときのパラメータ） | 秘密のヘッダーの値（32 文字以上。下の「秘密のヘッダーの値」） |
| `OriginHostedZoneId`、`OriginElasticIp` | `origin_hosted_zone_id`、`origin_elastic_ip` | オリジンの名前の A レコードも作るときに 2 つとも指定する（ステージング）。本番は空 |
| `OriginReadTimeoutSeconds`、`OriginKeepaliveTimeoutSeconds` | `origin_read_timeout_seconds`、`origin_keepalive_timeout_seconds` | 既定 30 秒・5 秒 |
| `GeoRestrictionType`、`GeoRestrictionCountries` | `geo_restriction_countries` | 地理的制限。**既定は使わない**（上の WAF の節） |

出力は `DistributionDomainName`（ステップ 2 の確認とステップ 3 で使う）と `OriginSecurityGroupId`（稼働サーバーに足す）。設定の一覧と理由は [ステップ 2 の 2-3](./step2-cloudfront.md#2-3-cloudfront-とオリジン用のセキュリティグループ)。

### 秘密のヘッダーの値

`OriginVerifyHeaderValue` は**デプロイのときのパラメータ**で渡す（32 文字以上）。`NoEcho` にしているのでテンプレートと `describe-stacks` には出ないが、CloudFront の設定を読める人には見える。

```bash
openssl rand -hex 32
```

## 使い方

どちらの書き方でも、変更セットを作り、中身を確かめてから反映する。CDK は合成したテンプレート（`cdk.out/<スタック名>.template.json`）を同じコマンドで反映する（[cdk/python/README.md](./cdk/python/README.md#デプロイ)）。

```bash
# 1. 変更セットを作る（反映はしない）
aws cloudformation deploy --region <リージョン> --no-execute-changeset \
  --template-file cloudformation/<ステップの定義>.yml \
  --stack-name <prefix>-<step1-certificate など> \
  --parameter-overrides <パラメータ>

# 2. 中身を確かめる
aws cloudformation describe-change-set --region <リージョン> \
  --stack-name <スタック名> --change-set-name <1 の出力の名前>

# 3. 反映する
aws cloudformation execute-change-set --region <リージョン> \
  --stack-name <スタック名> --change-set-name <1 の出力の名前>
```

ステップごとのコマンド（パラメータの具体的な形）は、各ステップのドキュメントにある。

| ステップ | 道具 | コマンド |
|---|---|---|
| 1 | CloudFormation | [ステップ 1 の 1-A](./step1-acm-certificate.md#1-a-acm-で作成する採用) |
| 2（WAF） | CDK | [ステップ 2 の 2-1](./step2-cloudfront.md#2-1-waf-の-web-acl) |
| 2（CloudFront） | CDK | [ステップ 2 の 2-3](./step2-cloudfront.md#2-3-cloudfront-とオリジン用のセキュリティグループ) |
| 3 | シェルスクリプト | [ステップ 3 の 3-1・3-2](./step3-dns-switch.md#3-1-流す変更を確かめる) |

## YAML と CDK の違い

合成の結果を YAML と項目ごとに比べた（セキュリティグループ、ディストリビューション、証明書、WAF。オプションはターゲットグループ、リスナー、ルールも）。違いは次のとおりで、動作は同じ見込み。

| 項目 | YAML | CDK の出力 |
|---|---|---|
| プレフィックスリストからの許可 | セキュリティグループの中に書く | 別のリソース（`AWS::EC2::SecurityGroupIngress`） |
| オリジン用のグループの外向き | 省略（既定の全許可） | 全許可を明示 |
| オリジンの `HTTPSPort` | `443` を明示 | 省略（既定の 443） |
| ACM の証明書の `Name` タグ | なし | CDK が付ける |
| 論理 ID | 短い名前 | CDK が生成する名前 |
| ALB の `deletion_protection.enabled`（オプション） | 省略（既定の `false`） | `false` を明示 |
| `RestrictToCloudFront`（オプションの C） | パラメータで切り替える | 設定値で切り替える（合成し直す） |

CDK の ALB のセキュリティグループの外向きは、L2 の `add_egress_rule` を使わず、L1 のプロパティで直接書いている。理由は `tls_termination_cdk/stacks/options/alb.py` のコメントのとおり。

## 確かめること

| 項目 | 内容 |
|---|---|
| AWS での検証 | 変更セットの作成と、実際のデプロイ。`cfn-lint` はプロパティの形を見るだけで、ID の実在や権限は見ない |
| オプションの既存のセキュリティグループへの許可の追加 | オプションの A・C で、スタックを消すと、足した許可も消える |

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09、2026-11-10）のは、各ステップのドキュメントの「参考」と、次のページ。

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
