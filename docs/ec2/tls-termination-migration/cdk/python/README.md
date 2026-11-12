# CDK（Python）版の使い方と実行コマンド

> 位置付け: `cdk/python/` の使い方。定義の中身（ルール、YAML との違い）は [definitions.md](../../definitions.md) を正本とし、ここでは**手元での準備・合成・デプロイのコマンド**をまとめる。
>
> 状態: 合成（`app.py` の実行）と `cfn-lint` までは確かめた（[definitions.md](../../definitions.md) の「状態」）。**AWS へのデプロイ（下の「デプロイ」のコマンド）は実行していない**。
>
> 作成日: 2026-11-12

## 用語

| 用語 | 意味 |
|---|---|
| 設定値ファイル | `config.example.yml` を写して環境の値に直したファイル（例: `config.yml`）。合成のときに指定する |
| 合成 | `app.py` を動かして、CloudFormation のテンプレート（JSON）を `cdk.out/` に出すこと（`cdk synth` と同じ） |
| CloudFront の証明書 | ACM のコンソールの「**証明書**」に出る、通常の公開証明書（`us-east-1`）。CloudFront に付ける。下の「ACM の証明書の種類」 |
| オリジンの証明書 | EC2 の httpd が持つ Let's Encrypt の証明書。CloudFront → EC2 では残る |
| 秘密のヘッダーの値 | CloudFront がオリジンへ付けるヘッダー（既定 `X-Origin-Verify`）の値。テンプレートに残さず、デプロイのときのパラメータ `OriginVerifyHeaderValue` で渡す |

## 方針

- CDK は**テンプレートを作るためだけ**に使う。デプロイは担当者が AWS CLI で変更セットを作り、確認してから反映する
- `cdk bootstrap` は要らない（ブートストラップのバージョンの確認をテンプレートに入れていない。`stacks/common.py` の `TerminationStack`）
- 合成は AWS を呼ばない（VPC などは ID で参照するだけで、検索しない）
- 1 回の合成で、6 つのスタックのテンプレートがすべて出る。**同じ環境にデプロイする構成は 1 つだけ**で、使うテンプレートを選んでデプロイする
- CDK で出したテンプレートでデプロイしたスタックを、`cloudformation/` の YAML で更新しない（論理 ID が違う。逆も同じ）

## ファイル

| ファイル | 内容 |
|---|---|
| `app.py` | 入口。設定値ファイルを読み、スタックを定義して合成する。設定値の誤りは終了コード 2 |
| `cdk.json` | `cdk` の CLI を使うときの設定（`app: python3 app.py`、既定の設定値ファイル `config.example.yml`） |
| `config.example.yml` | 設定値の例（値はすべて架空） |
| `requirements.txt` | `aws-cdk-lib` 2.275.0、`constructs` 10.8.1、`PyYAML` |
| `tls_termination_cdk/configuration.py` | 設定値の読み込みと検証 |
| `tls_termination_cdk/stacks/` | スタックの定義（[definitions.md の構成](../../definitions.md#構成)） |

## 出るスタック

`<prefix>` は設定値の `stack_name_prefix`。スタック名がそのままテンプレートのファイル名になる（`cdk.out/<スタック名>.template.json`）。

| スタック名 | リージョン | 内容 | デプロイのときのパラメータ |
|---|---|---|---|
| `<prefix>-alb-to-ec2` | `aws_region` | A. ALB → EC2 | なし |
| `<prefix>-cloudfront-to-ec2` | `aws_region` | B. CloudFront → EC2 | `OriginVerifyHeaderValue` |
| `<prefix>-cloudfront-to-ec2-same-domain` | `aws_region` | B. CloudFront → EC2（外部のドメイン名を変えない場合） | `OriginVerifyHeaderValue` |
| `<prefix>-cloudfront-alb-to-ec2` | `aws_region` | C. CloudFront → ALB → EC2 | `OriginVerifyHeaderValue` |
| `<prefix>-cloudfront-certificate` | `us-east-1` | CloudFront の証明書（ACM） | なし |
| `<prefix>-cloudfront-waf` | `us-east-1` | CloudFront 用の WAF の web ACL とログ | なし |

## 準備

Python 3 と Node.js（22 か 24。26 は jsii が未検証の警告を出すが合成はできた）が要る。`aws-cdk-lib` の取得は約 60 MB。合成だけなら `aws-cdk`（`cdk` の CLI）は要らない。

```bash
cd docs/ec2/tls-termination-migration/cdk/python
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

`.venv/` と `cdk.out/` は `.gitignore` に入っている。

## 設定値ファイル

```bash
cp config.example.yml config.yml   # 環境の値に直す（環境ごとに config.staging.yml などに分けてよい）
```

| 項目 | 必須 | 内容 |
|---|---|---|
| `stack_name_prefix` | ○ | スタック名の頭（例: `myapp-production`） |
| `aws_region` | ○ | ALB・CloudFront のスタックを置くリージョン（例: `ap-northeast-1`） |
| `vpc_id`、`availability_zones`、`subnet_ids` | ○ | インスタンスの VPC。サブネットは AZ と同じ順番で 1 つずつ |
| `instance_id`、`instance_security_group_id` | ○ | 既存のインスタンスと、そのセキュリティグループ |
| `cloudfront_prefix_list_id` | ○ | `com.amazonaws.global.cloudfront.origin-facing` の ID（下のコマンドで調べる） |
| `domain_name` | ○ | 利用者が使う名前（例: `app.example.com`） |
| `origin_domain_name` | ○ | CloudFront の接続先の名前。`domain_name` と同じにするとエラー |
| `alb_certificate_arn` | ○ | ALB のリージョンの ACM の証明書 |
| `cloudfront_certificate_arn` | ○ | `us-east-1` の ACM の証明書（CloudFront の証明書） |
| `cloudfront_web_acl_arn`、`alb_web_acl_arn` | | WAF の web ACL の ARN。空なら関連付けない |
| `certificate_hosted_zone_id` | | `domain_name` の Route 53 のホストゾーン。指定すると ACM の検証用のレコードを自動で作る（本番は外部の DNS なので空） |
| `origin_hosted_zone_id`、`origin_elastic_ip` | | `origin_domain_name` の A レコードも作るときに 2 つとも指定する |
| `waf_allowed_countries` ほか `waf_*` | | WAF の設定（[definitions.md の WAF](../../definitions.md#国の絞り込みwaf)） |
| `geo_restriction_countries` | | CloudFront の地理的制限。既定は空（使わない。使うと HTTP-01 の更新が止まる） |
| `restrict_to_cloudfront` | | C の 2 段階目で `true` にする |
| `new_app_port` ほか | | 既定値あり（`config.example.yml` の末尾） |

**注意: 必須の項目は、使わないスタックの分も埋める**。検証は全項目に対して行い、6 つのスタックを全部定義するため。たとえば B だけを使うときも `alb_certificate_arn` は空にできない。また、CloudFront の証明書のスタックを先に作るときは、まだ `cloudfront_certificate_arn` がないので、仮の値（例の値のまま）で合成し、証明書ができてから本当の値に書き換えて合成し直す。

未知の項目を書くとエラーになる（綴りの誤りを見つけるため）。

CloudFront のプレフィックスリストの ID:

```bash
aws ec2 describe-managed-prefix-lists --region ap-northeast-1 \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text
```

## 合成

どちらの形でもよい。

```bash
# cdk の CLI を使わない（Node.js は要る）
CDK_CONTEXT_JSON='{"config":"config.yml"}' CDK_OUTDIR=cdk.out .venv/bin/python app.py

# cdk の CLI を使う（npm install -g aws-cdk などで別に入れる。venv を有効にしてから）
source .venv/bin/activate
cdk synth -c config=config.yml
```

設定値ファイルを指定しないと `config.example.yml`（架空の値）で合成される。そのテンプレートはデプロイしない。

出たものを確かめる:

```bash
ls cdk.out/*.template.json
cfn-lint cdk.out/*.template.json   # 別にインストールが必要
```

## デプロイ

AWS CLI で、**変更セットを作る → 中身を見る → 反映する** の順に行う。下はスタック 1 つ分の形。

```bash
STACK=<スタック名>          # 例: myapp-production-cloudfront-to-ec2-same-domain
REGION=<リージョン>         # 上の「出るスタック」の表のリージョン

# 1. 変更セットを作る（反映はしない）
aws cloudformation deploy --region "$REGION" --no-execute-changeset \
  --template-file "cdk.out/$STACK.template.json" \
  --stack-name "$STACK"
#   CloudFront を使うスタックは次を足す
#   --parameter-overrides OriginVerifyHeaderValue=<秘密のヘッダーの値>

# 2. 中身を見る（1 の出力にも describe-change-set のコマンドが出る）
aws cloudformation list-change-sets --region "$REGION" --stack-name "$STACK"
aws cloudformation describe-change-set --region "$REGION" \
  --stack-name "$STACK" --change-set-name <変更セットの名前>

# 3. 反映して、終わるまで待つ
aws cloudformation execute-change-set --region "$REGION" \
  --stack-name "$STACK" --change-set-name <変更セットの名前>
aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$STACK"   # 更新なら stack-update-complete

# 4. 出力を見る
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query 'Stacks[0].Outputs' --output table
```

秘密のヘッダーの値は 32 文字以上。作り方と扱いは [definitions.md の秘密のヘッダーの値](../../definitions.md#秘密のヘッダーの値)。

```bash
openssl rand -hex 32
```

- 2 回目以降の更新で `OriginVerifyHeaderValue` を変えないなら、`--parameter-overrides OriginVerifyHeaderValue=<同じ値>` をもう一度渡す（`NoEcho` のため、CloudFormation から値を読み出せない）
- テンプレートが 51,200 バイトを超えると、`aws cloudformation deploy` に `--s3-bucket` が要る。今の定義の大きさでは確かめていない

## 構成ごとの順番

### B. CloudFront → EC2（外部のドメイン名を変えない場合。今進めている案）

| # | 行うこと | コマンド・確かめること |
|---|---|---|
| 1 | 設定値ファイルを作り、合成する | 上の「設定値ファイル」「合成」。`cloudfront_certificate_arn`・`cloudfront_web_acl_arn` はまだ仮の値・空でよい |
| 2 | `<prefix>-cloudfront-certificate` をデプロイ（`us-east-1`） | `certificate_hosted_zone_id` が空なら、ACM が示す検証用の CNAME を DNS に足すまでスタックは `CREATE_IN_PROGRESS` のまま待つ（本番の手順は [external-dns-certificate.md](../../external-dns-certificate.md)） |
| 3 | `<prefix>-cloudfront-waf` をデプロイ（`us-east-1`） | |
| 4 | 2 と 3 の出力を設定値ファイルに書く | `CertificateArn` → `cloudfront_certificate_arn`、`WebAclArn` → `cloudfront_web_acl_arn` |
| 5 | 合成し直す | |
| 6 | `<prefix>-cloudfront-to-ec2-same-domain` をデプロイ（`aws_region`） | `OriginVerifyHeaderValue` を渡す |
| 7 | 出力 `OriginSecurityGroupId` をインスタンスに**足す** | 下のコマンド |
| 8 | httpd の設定、確かめ、DNS の切り替え | [cloudfront-to-ec2-httpd.md](../../cloudfront-to-ec2-httpd.md)、[cloudfront-to-ec2-same-domain.md](../../cloudfront-to-ec2-same-domain.md) |

7 のセキュリティグループの追加（`--groups` は全部を置き換えるので、今のグループも並べる）:

```bash
aws ec2 describe-instances --instance-ids <インスタンス ID> \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text
aws ec2 modify-instance-attribute --instance-id <インスタンス ID> \
  --groups <今のグループ…> <OriginSecurityGroupId>
```

### A. ALB → EC2

`alb_certificate_arn`（ALB のリージョンの ACM の証明書）を用意してから、`<prefix>-alb-to-ec2` をデプロイする。パラメータはない。出力 `LoadBalancerDnsName` に DNS を向ける。手順は [alb-to-ec2.md](../../alb-to-ec2.md)。

### C. CloudFront → ALB → EC2

1. CloudFront の証明書（と WAF）を B の 2〜5 と同じく用意する
2. `restrict_to_cloudfront: false` で合成し、`<prefix>-cloudfront-alb-to-ec2` をデプロイする（`OriginVerifyHeaderValue` を渡す）。出力 `LoadBalancerDnsName` に `origin_domain_name` を向ける
3. DNS を CloudFront へ向け、元の TTL が過ぎるまで待つ
4. `restrict_to_cloudfront: true` にして合成し直し、同じスタックを更新する

## 撤去

```bash
aws cloudformation delete-stack --region <リージョン> --stack-name <スタック名>
aws cloudformation wait stack-delete-complete --region <リージョン> --stack-name <スタック名>
```

- 先にインスタンスから `OriginSecurityGroupId` を外す（付けたままだと、グループを消せずに削除が失敗する）
- 既存のインスタンスのセキュリティグループに足した許可（A・C）も、スタックと一緒に消える
- CloudFront の証明書・WAF のスタックは、CloudFront のスタックを消した後に消す（使われている間は消せない）

## ACM の証明書の種類

ACM のコンソールには「**証明書**」と「**ACME 証明書**」がある。**CloudFront・ALB に付けるのは「証明書」**（`RequestCertificate` で発行する通常の公開証明書）で、このスタック（`<prefix>-cloudfront-certificate`）が作るのもこちらである。

| | 証明書（通常の公開証明書） | ACME 証明書 |
|---|---|---|
| 発行の仕方 | ACM に要求する（コンソール、`RequestCertificate`、CloudFormation） | 自分のサーバーの ACME クライアント（Certbot など）が、ACM の ACME エンドポイントに要求する。管理者が先にドメインを承認し、EAB の認証情報を配る |
| CloudFront・ALB に付けられるか | **付けられる** | **付けられない**（AWS のドキュメントに明記） |
| 秘密鍵 | ACM が持つ | ACME クライアントが持つ。ACM は見ない |
| 更新 | ACM が自動で行う | ACME クライアントが行う。ACM の自動更新は効かない |
| 有効期間 | ACME 証明書より長い | 45 日 |
| 料金（2026-11-12 確認） | AWS のサービスに付けて使うなら無料 | FQDN 1 つで月 $1（1,000 件まで。件数で下がる）、ワイルドカードは月 $5 |
| 向いている用途 | CloudFront、ALB、API Gateway | EC2 の httpd など、自分で管理するサーバー |

ACME 証明書は、Let's Encrypt と同じ使い方で発行元が ACM になるものと考えてよい。この移行では、オリジンの証明書は Let's Encrypt のまま続けると決めている（[cloudfront-to-ec2-httpd.md の証明書の更新](../../cloudfront-to-ec2-httpd.md#証明書の更新)）。ACME 証明書をオリジンの証明書に使う案は、そこで見送りとしている。

## 参考

AWS のドキュメントと照らし合わせた（2026-11-12）。

- [ACME certificate automation（ACME 証明書は ELB・CloudFront に付けられない、45 日、秘密鍵と更新は ACME クライアント）](https://docs.aws.amazon.com/acm/latest/userguide/acm-acme.html)
- [AWS Certificate Manager Pricing](https://aws.amazon.com/certificate-manager/pricing/)
- [AWS Certificate Manager now supports the ACME protocol for public certificates（2026-07 の発表）](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-certificate-manager-acme/)
- [aws cloudformation deploy](https://docs.aws.amazon.com/cli/latest/reference/cloudformation/deploy/)
- 定義の側の参考は [definitions.md の参考](../../definitions.md#参考)
