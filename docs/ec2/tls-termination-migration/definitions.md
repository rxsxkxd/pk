# 3 つの構成の ALB・CloudFront の定義

> 位置付け: [3 つの構成](./README.md)の ALB と CloudFront を、CloudFormation の YAML と CDK（Python）で定義したもの。同じ構成を 2 通りの書き方で置いている。
>
> 状態: **骨組み（AWS へのデプロイはしていない）**。YAML と CDK の出力は `cfn-lint` を通した。CDK は `aws-cdk-lib` 2.275.0 で合成し、`restrict_to_cloudfront` の両方の値と WAF を付けた場合を確かめた。合成の結果は YAML と内容を突き合わせた（下の「YAML と CDK の違い」）。
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
      cloudfront_alb_to_ec2.py
```

CDK は L2 で書いているので、論理 ID は CloudFormation の YAML と違う。YAML でデプロイしたスタックを CDK の出力で更新しない。逆も同じ。

## 定義に含めるもの

| 種類 | リソース |
|---|---|
| ALB | ロードバランサー、ターゲットグループ（`new_app_b`: 8080 番、`old_app_a`: 80 番）、HTTPS・HTTP のリスナー、パスとヘッダーのルール |
| CloudFront | ディストリビューション（HTTPS only、`CachingDisabled`、`AllViewer`、秘密のヘッダー）。CloudFront → EC2 の 2 つの定義は、地理的制限（既定は日本だけを許可）も含む |
| セキュリティグループ | ALB 用、CloudFront → EC2 のオリジン用、既存のインスタンスのグループへの許可の追加 |
| WAF | **関連付けだけ**（web ACL の ARN を渡したとき） |

## 定義に含めないもの

| もの | 理由・行うこと |
|---|---|
| ACM の証明書 | CloudFront 用は `us-east-1` に要り、スタックのリージョンと分かれる。先に作って ARN を渡す（外部のドメイン名を変えない構成は、`us-east-1` の証明書のスタックを別に用意している） |
| WAF の web ACL | 中身のルールは要件次第。先に作って ARN を渡す。CloudFront 用は `us-east-1` |
| DNS のレコード | 切り替えの時点を担当者が決めるため。`origin.<ドメイン>` と本番の名前は別に用意する |
| インスタンスへのセキュリティグループの付け替え | CloudFront → EC2 の出力 `OriginSecurityGroupId` を、既存のグループに**足して**付ける（`modify-instance-attribute --groups` は全部を置き換えるので、既存のグループも並べる） |
| 静的なファイルのキャッシュ | 使うと決まってから足す |
| CloudFront → ALB → EC2 の地理的制限 | 国で絞る方法を決めてから足す（CloudFront → EC2 だけ先に入れた） |

**地理的制限（CloudFront → EC2）**: パラメータ `GeoRestrictionType`（既定 `whitelist`）と `GeoRestrictionCountries`（既定 `JP`）で決める。`GeoRestrictionType=none` で制限しない。CDK は設定値の `geo_restriction_countries`（既定 `[JP]`。空のリストで制限しない）。止めた要求には CloudFront が 403 を返す。**有効にすると、EC2 の Let's Encrypt の証明書を CloudFront 経由の HTTP-01 で更新できなくなる**（[証明書の更新](./cloudfront-to-ec2-httpd.md#証明書の更新)）。

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
| `cloudfront-to-ec2-same-domain.yml` | `ap-northeast-1` | CloudFront、オリジン用のセキュリティグループ、`origin.app.example.com` の Route 53 のレコード（任意） |

| パラメータ | 内容 |
|---|---|
| 証明書のスタックの `HostedZoneId` | `app.example.com` のホストゾーンが同じアカウントの Route 53 にあるなら指定する。検証用のレコードが自動で作られる。空にすると、ACM が示す CNAME を DNS に足すまで、スタックは `CREATE_IN_PROGRESS` のまま待つ |
| `OriginHostedZoneId`、`OriginElasticIp` | `origin.app.example.com` のレコードもこのスタックで作るときに指定する。別の DNS で管理するなら空にして、手で作る |

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

# 3. CloudFront など（ap-northeast-1）。変更セットを確認してから反映する
aws cloudformation deploy --region ap-northeast-1 --no-execute-changeset \
  --template-file cloudformation/cloudfront-to-ec2-same-domain.yml \
  --stack-name <スタック名> \
  --parameter-overrides VpcId=<VPC> CloudFrontPrefixListId=<pl-...> \
    DomainName=app.example.com OriginDomainName=origin.app.example.com \
    CloudFrontCertificateArn=<2 の ARN> OriginVerifyHeaderValue=<秘密の値> \
    OriginHostedZoneId=<ホストゾーン ID> OriginElasticIp=<Elastic IP>
```

CloudFront のプレフィックスリストの ID は、上の `describe-managed-prefix-lists` に `--region ap-northeast-1` を付けて調べる。

CDK では、`<prefix>-cloudfront-certificate` を先に合成・デプロイし、出力の ARN を設定値の `cloudfront_certificate_arn` に書いてから、`<prefix>-cloudfront-to-ec2-same-domain` を合成する。

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
