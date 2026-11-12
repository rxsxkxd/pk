# CDK（Python）版の使い方と実行コマンド

> 位置付け: `cdk/python/` の使い方。B. CloudFront → EC2 への移行の 3 つのステップのうち、**手順で CDK を使うのはステップ 2**（ステップ 1 は CloudFormation の YAML、ステップ 3 はシェルスクリプト。[README の T9](../../README.md#決めたこと)）。ステップ 1 のスタックも同じ内容で定義しているが、手順では使わない。定義の中身（ルール、YAML との違い）は [definitions.md](../../definitions.md) を正本とし、ここでは**手元での準備・合成・デプロイのコマンド**をまとめる。手順の全体は [README](../../README.md#3-つのステップ)。
>
> 状態: 合成（`app.py` の実行）は確かめた（2026-11-12。Node.js 26、`aws-cdk-lib` 2.275.0）。3 つのステップの形に組み替えた後も、合成したテンプレートは `cfn-lint` 1.60.0 を警告なしで通り、組み替える前とリソースの中身が同じだった（違いはスタック名から決まる名前と説明だけ）。**AWS へのデプロイ（下の「デプロイ」のコマンド）は実行していない**。
>
> 作成日: 2026-11-12（3 つのステップの形に組み替えた: 2026-11-12）

## 用語

[README の用語](../../README.md#用語)に加えて、次の語を使う。

| 用語 | 意味 |
|---|---|
| 設定値ファイル | `config.example.yml` を写して環境の値に直したファイル（例 `config.yml`）。合成のときに指定する |
| 合成 | `app.py` を動かして、CloudFormation のテンプレート（JSON）を `cdk.out/` に出すこと（`cdk synth` と同じ） |
| 本線のスタック | 採用した B. CloudFront → EC2 のステップ 1・2 のスタック（3 つ。手順で使うのはステップ 2 の 2 つ） |
| オプションのスタック | 採用しなかった ALB を使う構成のスタック。設定値の `option_stacks` で指定したときだけ合成する |

## 方針

- CDK は**テンプレートを作るためだけ**に使う。デプロイは担当者が AWS CLI で変更セットを作り、確認してから反映する
- `cdk bootstrap` は要らない（ブートストラップのバージョンの確認をテンプレートに入れていない。`stacks/common.py` の `TerminationStack`）。テンプレートが参照するファイル（アセット）はテンプレート自身だけで、`cdk.out/*.assets.json` に書かれる S3 のバケットは使わない
- 合成は AWS を呼ばない（VPC などは ID で参照するだけで、検索しない）
- ステップ 3（DNS の向き先の変更）は CDK に含めない（[README の T8](../../README.md#決めたこと)）
- CDK で出したテンプレートでデプロイしたスタックを、`cloudformation/` の YAML で更新しない（論理 ID が違う。逆も同じ）

## 出るスタック

`<prefix>` は設定値の `stack_name_prefix`。スタック名がそのままテンプレートのファイル名になる（`cdk.out/<スタック名>.template.json`）。パラメータと出力は、2026-11-12 に合成の結果で確かめた。

### 本線（B. CloudFront → EC2）

| ステップ | スタック名 | リージョン | 内容 | 合成する条件 | デプロイのときのパラメータ | 出力 |
|---|---|---|---|---|---|---|
| 1 | `<prefix>-step1-certificate` | `us-east-1` | CloudFront の証明書（ACM で作成）。**手順では使わない**（ステップ 1 は `cloudformation/step1-certificate.yml`） | いつも | なし | `CertificateArn` |
| 2 | `<prefix>-step2-waf` | `us-east-1` | CloudFront 用の WAF の web ACL とログ | いつも | なし | `WebAclArn`、`WebAclLogGroupName` |
| 2 | `<prefix>-step2-cloudfront` | `aws_region` | CloudFront、オリジン用のセキュリティグループ、オリジンの名前の Route 53 のレコード（任意） | `cloudfront_certificate_arn` がある | `OriginVerifyHeaderValue` | `DistributionDomainName`、`OriginSecurityGroupId` |

`cloudfront_certificate_arn` が空の間は、`<prefix>-step2-cloudfront` を合成せず、標準エラーに次のように出す（終了コードは 0）。ステップ 1 の前は空のままでよい。

```
定義しなかったスタック: myapp-production-step2-cloudfront（cloudfront_certificate_arn が空。ステップ 1 の後に書く）
```

### オプション（採用しなかった構成）

| スタック名 | リージョン | 内容 | 合成する条件 | デプロイのときのパラメータ |
|---|---|---|---|---|
| `<prefix>-option-alb-to-ec2` | `aws_region` | A. ALB → EC2 | `option_stacks` に `alb-to-ec2` | なし |
| `<prefix>-option-cloudfront-alb-to-ec2` | `aws_region` | C. CloudFront → ALB → EC2 | `option_stacks` に `cloudfront-alb-to-ec2` | `OriginVerifyHeaderValue` |

`option_stacks` に書いた構成に要る項目（`subnet_ids`、`instance_id`、`instance_security_group_id`、`alb_certificate_arn`。C は `cloudfront_certificate_arn` も）が欠けていると、合成は終了コード 2 で止まる。

## ファイル

| ファイル | 内容 |
|---|---|
| `app.py` | 入口。設定値ファイルを読み、スタックを定義して合成する。設定値の誤りは終了コード 2。定義しなかった本線のスタックを標準エラーに出す |
| `cdk.json` | `cdk` の CLI を使うときの設定（`app: python3 app.py`、既定の設定値ファイル `config.example.yml`） |
| `config.example.yml` | 設定値の例（値はすべて架空）。ステップごとに区切って並べている |
| `requirements.txt` | `aws-cdk-lib` 2.275.0、`constructs` 10.8.1、`PyYAML` |
| `tls_termination_cdk/configuration.py` | 設定値の読み込みと検証 |
| `tls_termination_cdk/stacks/` | スタックの定義（`step1_certificate.py`、`step2_waf.py`、`step2_cloudfront.py`、オプションは `options/`） |

## 準備

Python 3 と Node.js（22 か 24。26 は jsii が未検証の警告を出すが合成はできた。警告は `JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1` で消せる）が要る。`aws-cdk-lib` の取得は約 60 MB。合成だけなら `aws-cdk`（`cdk` の CLI）は要らない。

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

| 項目 | 必須 | 使うステップ | 内容 |
|---|---|---|---|
| `stack_name_prefix` | ○ | すべて | スタック名の頭（例 `myapp-production`） |
| `aws_region` | ○ | 2 | CloudFront のスタックを置くリージョン（例 `ap-northeast-1`）。ステップ 1 と WAF のスタックはいつも `us-east-1` |
| `vpc_id`、`availability_zones` | ○ | 2 | 稼働サーバーの VPC と、その AZ |
| `cloudfront_prefix_list_id` | ○ | 2 | `com.amazonaws.global.cloudfront.origin-facing` の ID（下のコマンドで調べる） |
| `domain_name` | ○ | 1・2 | 利用者のドメイン名（例 `app.example.com`） |
| `origin_domain_name` | ○ | 2 | オリジンの名前。`domain_name` と同じにするとエラー |
| `certificate_hosted_zone_id` | | 1 | `<prefix>-step1-certificate` でだけ使う（手順では使わないので、空のままでよい） |
| `cloudfront_certificate_arn` | | 2 | ステップ 1（CloudFormation）の出力 `CertificateArn`（または登録した証明書の ARN）。空の間はステップ 2 の CloudFront のスタックを合成しない |
| `cloudfront_web_acl_arn` | | 2 | `<prefix>-step2-waf` の出力 `WebAclArn`。空なら関連付けない（**本番では空にしない**） |
| `origin_hosted_zone_id`、`origin_elastic_ip` | | 2 | オリジンの名前の A レコードも作るときに 2 つとも指定する（ステージング）。本番は空 |
| `waf_allowed_countries` ほか `waf_*` | | 2 | WAF の設定（[definitions.md の WAF](../../definitions.md#ステップ-2-の-waf国の絞り込み)） |
| `geo_restriction_countries` | | 2 | CloudFront の地理的制限。既定は空（使わない。使うと HTTP-01 の更新が止まる） |
| `origin_read_timeout_seconds` ほか | | 2 | 既定値あり |
| `option_stacks` | | オプション | 合成するオプションの構成（`alb-to-ec2`、`cloudfront-alb-to-ec2`）。既定は空 |
| `subnet_ids`、`instance_id`、`instance_security_group_id`、`alb_certificate_arn`、`alb_web_acl_arn`、`restrict_to_cloudfront` ほか | | オプション | `option_stacks` に書いた構成でだけ使う |

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
STACK=<スタック名>          # 例: myapp-production-step2-cloudfront
REGION=<リージョン>         # 上の「出るスタック」の表のリージョン

# 1. 変更セットを作る（反映はしない）
aws cloudformation deploy --region "$REGION" --no-execute-changeset \
  --template-file "cdk.out/$STACK.template.json" \
  --stack-name "$STACK"
#   <prefix>-step2-cloudfront（とオプションの C）は次を足す
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

- 秘密のヘッダーの値は 32 文字以上（`openssl rand -hex 32`。[準備の 4](../../step0-preparation.md#4-秘密のヘッダーの値を作る)）
- 2 回目以降の更新で `OriginVerifyHeaderValue` を変えないなら、`--parameter-overrides OriginVerifyHeaderValue=<同じ値>` をもう一度渡す（`NoEcho` のため、CloudFormation から値を読み出せない）
- テンプレートが 51,200 バイトを超えると、`aws cloudformation deploy` に `--s3-bucket` が要る。`config.example.yml` で合成した大きさは、いちばん大きい `<prefix>-step2-waf` で約 10 KB、ほかは 9 KB 以下なので要らない（2026-11-12）。例外の IP を数百件並べると大きくなる

## 3 つのステップでの使い方

確認の中身は各ステップのドキュメントにある。CDK で行うのは、スタックの合成とデプロイの部分だけ。

| # | ステップ | 行うこと | 確かめること |
|---|---|---|---|
| 1 | ステップ 1 | **CDK は使わない**。CloudFormation の YAML（`cloudformation/step1-certificate.yml`）でデプロイし、出力の `CertificateArn` を設定値の `cloudfront_certificate_arn` に書く | [確認 1](../../step1-acm-certificate.md#確認-1ステップ-2-へ進む条件) |
| 2 | ステップ 2 | 設定値ファイルを作って合成する（`cloudfront_web_acl_arn` は空のまま） → `<prefix>-step2-waf` をデプロイ（`us-east-1`） → 出力の `WebAclArn` を設定値に書いて合成し直す → `<prefix>-step2-cloudfront` をデプロイ（`aws_region`。`OriginVerifyHeaderValue` を渡す） → 出力 `OriginSecurityGroupId` を稼働サーバーに足す | [確認 2](../../step2-cloudfront.md#確認-2ステップ-3-へ進む条件) |
| 3 | ステップ 3 | **CDK は使わない**。シェルスクリプト `scripts/step3-dns-switch.sh` で向き先を変える | [確認 3](../../step3-dns-switch.md#確認-3片付けへ進む条件) |

### オプション（採用しなかった構成）

- A. ALB → EC2: `option_stacks: [alb-to-ec2]` と `alb_certificate_arn` ほかを書いて合成し、`<prefix>-option-alb-to-ec2` をデプロイする。手順は [options/alb-to-ec2.md](../../options/alb-to-ec2.md)
- C. CloudFront → ALB → EC2: `option_stacks: [cloudfront-alb-to-ec2]` で `restrict_to_cloudfront: false` のまま合成・デプロイし、DNS を CloudFront へ向けて元の TTL が過ぎてから、`true` にして合成し直し、同じスタックを更新する。手順は [options/cloudfront-alb-to-ec2.md](../../options/cloudfront-alb-to-ec2.md)

## 撤去

逆の順（ステップ 2 の CloudFront → ステップ 2 の WAF → ステップ 1）に消す。

```bash
aws cloudformation delete-stack --region <リージョン> --stack-name <スタック名>
aws cloudformation wait stack-delete-complete --region <リージョン> --stack-name <スタック名>
```

- 先に稼働サーバーから `OriginSecurityGroupId` を外す（付けたままだと、グループを消せずに削除が失敗する）
- WAF と証明書のスタックは、CloudFront のスタックを消した後でないと消せない（使われている間は消せない）
- ステップ 3 の後なら、先に DNS を元に戻す（[ステップ 3 の元に戻す](../../step3-dns-switch.md#元に戻す)）
- オプションの A・C で既存のインスタンスのセキュリティグループに足した許可は、スタックと一緒に消える

## ACM の証明書の種類

ACM のコンソールには「**証明書**」と「**ACME 証明書**」がある。**CloudFront・ALB に付けるのは「証明書」**（`RequestCertificate` で発行する通常の公開証明書、または `ImportCertificate` で登録した証明書）で、ステップ 1 のスタック（`<prefix>-step1-certificate`）が作るのもこちらである。

| | 証明書（通常の公開証明書） | ACME 証明書 |
|---|---|---|
| 発行の仕方 | ACM に要求する（コンソール、`RequestCertificate`、CloudFormation） | 自分のサーバーの ACME クライアント（Certbot など）が、ACM の ACME エンドポイントに要求する。管理者が先にドメインを承認し、EAB の認証情報を配る |
| CloudFront・ALB に付けられるか | **付けられる** | **付けられない**（AWS のドキュメントに明記） |
| 秘密鍵 | ACM が持つ | ACME クライアントが持つ。ACM は見ない |
| 更新 | ACM が自動で行う（登録した証明書は除く） | ACME クライアントが行う。ACM の自動更新は効かない |
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
