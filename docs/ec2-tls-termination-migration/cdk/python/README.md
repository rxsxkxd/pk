# CDK（Python）版の使い方と実行コマンド

> 位置付け: `cdk/python/` の使い方。B. CloudFront → EC2 への移行の 3 つのステップのうち、**ステップ 2 は CDK で行う**。ステップ 1 は CloudFormation の YAML と CDK のどちらでもよく、手順書に両方を書いている。ステップ 3 はシェルスクリプト（[README の T9](../../README.md#決めたこと)）。定義の中身（ルール、YAML との違い）は [definitions.md](../../definitions.md) を正本とし、ここでは**手元での準備・合成・デプロイのコマンド**をまとめる。デプロイの仕方は 2 通りある（[CDK で直接反映する](#方法-1-cdk-で直接反映するcdk-deploy)・[CloudFormation のテンプレートを出して反映する](#方法-2-cloudformation-のテンプレートyamlを出して-aws-cli-で反映する)）。手順の全体は [README](../../README.md#3-つのステップ)。
>
> 状態: 合成（`app.py` の実行）は確かめた（2026-11-12。Node.js 26、`aws-cdk-lib` 2.275.0）。3 つのステップの形に組み替えた後も、合成したテンプレートは `cfn-lint` 1.60.0 を警告なしで通り、組み替える前とリソースの中身が同じだった（違いはスタック名から決まる名前と説明だけ）。`cdk` の CLI（`aws-cdk` 2.1148.1）を入れ、`cdk list` と `cdk synth` を確かめた（2026-11-13）。`cdk synth <スタック名>` が標準出力に出す YAML は、`app.py` を直接動かして出した JSON と中身が同じだった（本線の 3 つのスタック）。**AWS へのデプロイ（下の「デプロイ」のコマンド）と、AWS を読む `cdk diff`・`cdk deploy` は実行していない**（コマンドとオプションは AWS のドキュメントと `cdk deploy --help` で確かめた）。
>
> 作成日: 2026-11-12（3 つのステップの形に組み替えた: 2026-11-12。デプロイの 2 通りの仕方を書いた: 2026-11-13）

## 用語

[README の用語](../../README.md#用語)に加えて、次の語を使う。

| 用語 | 意味 |
|---|---|
| 設定値ファイル | `config.example.yml` を写して環境の値に直したファイル（例 `config.yml`）。合成のときに指定する |
| 合成 | `app.py` を動かして、CloudFormation のテンプレート（JSON）を `cdk.out/` に出すこと（`cdk synth` と同じ） |
| `cdk` の CLI | npm のパッケージ `aws-cdk` のコマンド `cdk`。`cdk deploy` と、テンプレートを YAML で出す `cdk synth` に要る。Python の `aws-cdk-lib` とは別に入れる |
| ブートストラップ | `cdk bootstrap` で、アカウントとリージョンごとに CDK 用の S3 のバケット・ECR・IAM ロール（スタック `CDKToolkit`）を作ること |
| 本線のスタック | 採用した B. CloudFront → EC2 のステップ 1・2 のスタック（3 つ） |
| オプションのスタック | 採用しなかった ALB を使う構成のスタック。設定値の `option_stacks` で指定したときだけ合成する |

## 方針

- デプロイは 2 通りのどちらかで行う。どちらも、**変更の中身を見てから反映する**
  - [方法 1](#方法-1-cdk-で直接反映するcdk-deploy): `cdk deploy` で CDK から直接反映する
  - [方法 2](#方法-2-cloudformation-のテンプレートyamlを出して-aws-cli-で反映する): CDK から CloudFormation のテンプレート（YAML）を出し、AWS CLI で変更セットを作って反映する
- 1 つの環境では、どちらか一方に決めて使い続ける（同じテンプレートを同じスタック名で反映するので、混ぜても同じ結果になる見込みだが、確かめていない。パラメータの渡し方が違うので、混ぜると取り違えやすい）
- `cdk bootstrap` はしない。AWS のドキュメントでは、ブートストラップしていない環境でも「アセットがなく、テンプレートが 51,200 バイト未満のスタック」はデプロイできる。この定義のスタックはアセットを持たず（ファイルや Docker イメージを参照しない。`cdk.out/*.assets.json` に載るのはテンプレート自身だけであることを、Route 53 のゾーンとオプションを指定した設定値でも合成して確かめた。2026-11-13）、本線のテンプレートはどれも 4 KB 未満（オプションの C で約 9 KB。2026-11-13）。ブートストラップのバージョンの確認もテンプレートに入れていない（`stacks/common.py` の `TerminationStack`）。方法 2 は CloudFormation を直接使うので、もともとブートストラップと関係がない
- 合成は AWS を呼ばない（VPC などは ID で参照するだけで、検索しない）
- ステップ 3（DNS の向き先の変更）は CDK に含めない（[README の T8](../../README.md#決めたこと)）
- CDK で出したテンプレートでデプロイしたスタックを、`cloudformation/` の YAML で更新しない（論理 ID が違う。逆も同じ）

## 出るスタック

`<prefix>` は設定値の `stack_name_prefix`。スタック名がそのままテンプレートのファイル名になる（`cdk.out/<スタック名>.template.json`）。パラメータと出力は、2026-11-12 に合成の結果で確かめた。

### 本線（B. CloudFront → EC2）

| ステップ | スタック名 | リージョン | 内容 | 合成する条件 | デプロイのときのパラメータ | 出力 |
|---|---|---|---|---|---|---|
| 1 | `<prefix>-step1-certificate` | `us-east-1` | CloudFront の証明書（ACM で作成）。ステップ 1 を CDK で行うときに使う（CloudFormation の YAML `cloudformation/step1-certificate.yml` で行うなら使わない） | いつも | なし | `CertificateArn` |
| 2 | `<prefix>-step2-waf` | `us-east-1` | CloudFront 用の WAF の web ACL（国の絞り込みだけ。マネージドルールとログは[オプション](../../options/waf-managed-rules.md)） | いつも | なし | `WebAclArn` |
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
| `cdk.json` | `cdk` の CLI を使うときの設定（`app: python3 app.py`、既定の設定値ファイル `config.example.yml`、`pathMetadata: false`） |
| `config.example.yml` | 設定値の例（値はすべて架空）。ステップごとに区切って並べている |
| `requirements.txt` | `aws-cdk-lib` 2.275.0、`constructs` 10.8.1、`PyYAML` |
| `tls_termination_cdk/configuration.py` | 設定値の読み込みと検証 |
| `tls_termination_cdk/stacks/` | スタックの定義（`step1_certificate.py`、`step2_waf.py`、`step2_cloudfront.py`、オプションは `options/`） |

## 準備

Python 3 と Node.js（22 か 24。26 は jsii が未検証の警告を出すが合成はできた。警告は `JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1` で消せる）が要る。`aws-cdk-lib` の取得は約 60 MB。

```bash
cd docs/ec2/tls-termination-migration/cdk/python
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

`cdk` の CLI は、方法 1（`cdk deploy`）と、方法 2 でテンプレートを YAML で出すときに要る。npm で別に入れる（2.1148.1 は依存がなく、展開後 28 MB。2026-11-13）。方法 2 で JSON のテンプレートでよければ、`cdk` の CLI は要らない（[合成](#合成)の 1 つ目の形）。

```bash
npm install -g aws-cdk
cdk --version          # 確かめた版: 2.1148.1 (build fcf5e34)
```

- `cdk` の CLI は、既定で匿名の利用状況（テレメトリー）を AWS に送る。止めるなら `cdk cli-telemetry --disable`（`cdk --help` の記述。動かしてはいない）
- `cdk` のコマンドは、標準エラーに「85 feature flags are not configured」などの案内を出す。テンプレートには関係しない

`cdk.json` の `app` は `python3 app.py` なので、`cdk` のコマンドは venv を有効にしてから流す（`source .venv/bin/activate`）。

`.venv/`、`cdk.out/`、`templates/`（方法 2 で出す YAML）は `.gitignore` に入っている。

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
| `certificate_hosted_zone_id` | | 1 | ステップ 1 を CDK で行うときに、`domain_name` の Route 53 のホストゾーン ID を書く（ステージング）。空なら検証用の CNAME を手で足す（本番）。ステップ 1 を CloudFormation の YAML で行うなら空のままでよい |
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

どちらの形でもよい。どちらも `cdk.out/<スタック名>.template.json` に出る。

```bash
# cdk の CLI を使わない（Node.js は要る）
CDK_CONTEXT_JSON='{"config":"config.yml"}' CDK_OUTDIR=cdk.out .venv/bin/python app.py

# cdk の CLI を使う（venv を有効にしてから）
source .venv/bin/activate
cdk synth -c config=config.yml --quiet
```

`cdk synth` にスタック名を 1 つ渡すと、そのスタックのテンプレートが YAML で標準出力にも出る（AWS のドキュメントの記述。手元でも確かめた）。方法 2 ではこれを使う。`--quiet` は標準出力に出さない。「定義しなかったスタック」の知らせは標準エラーに出るので、YAML には混ざらない。定義していないスタック（`cloudfront_certificate_arn` が空の間の `<prefix>-step2-cloudfront`）を指定すると、`No stacks match the name(s)` で止まる（終了コード 1）。

`cdk` の CLI は、既定で各リソースに `Metadata: aws:cdk:path`（CDK の中の場所）を足す。`cdk.json` の `pathMetadata: false` で足さないようにしている。これで、`cdk synth`・`cdk deploy` のテンプレートと、`app.py` を直接動かして出したテンプレートの中身が同じになる（方法 1 と方法 2 で、反映するテンプレートがそろう）。

設定値ファイルを指定しないと `config.example.yml`（架空の値）で合成される。そのテンプレートはデプロイしない。

出たものを確かめる:

```bash
ls cdk.out/*.template.json
cfn-lint cdk.out/*.template.json   # 別にインストールが必要
```

## デプロイ

2 通りある。どちらもスタックを 1 つずつ、**変更の中身を見てから**反映する。どちらを使うかは環境ごとに決める（[方針](#方針)）。

| | 方法 1: CDK で直接反映する | 方法 2: テンプレート（YAML）を出して AWS CLI で反映する |
|---|---|---|
| 使うコマンド | `cdk diff`・`cdk deploy` | `cdk synth` → `aws cloudformation deploy` |
| 要るもの | `cdk` の CLI | `cdk` の CLI（JSON でよければ要らない）と AWS CLI |
| 反映するテンプレートが手元に残るか | `cdk.out/` に JSON（合成のたびに上書き） | `templates/<スタック名>.template.yml`。差分を見る・`cfn-lint` にかける・人に渡すのに使える |
| 変更の中身を見る | `cdk diff`（今のスタックとテンプレートを比べる）と、反映の前の確認の問い合わせ | 変更セット（`describe-change-set`） |
| 秘密のヘッダーの値の渡し方 | `--parameters <スタック名>:OriginVerifyHeaderValue=<値>` | `--parameter-overrides OriginVerifyHeaderValue=<値>` |
| 2 回目以降の更新で、渡さなかったパラメータ | 前の値のまま（`--previous-parameters` の既定が `true`） | 前の値のまま（`aws cloudformation deploy` の `--parameter-overrides` の説明） |
| ブートストラップ | しない（[方針](#方針)のとおり、この定義の大きさなら要らない見込み。確かめていない） | 関係がない |

秘密のヘッダーの値は 32 文字以上（`openssl rand -hex 32`。[準備の 4](../../step0-preparation.md#4-秘密のヘッダーの値を作る)）。どちらの方法でもコマンドラインに値を書くので、シェルの履歴に残る。流した後に履歴から消すか、値を環境変数に読み込んでから渡す。

### 方法 1: CDK で直接反映する（cdk deploy）

```bash
source .venv/bin/activate
STACK=<スタック名>          # 例: myapp-production-step2-cloudfront

# 1. 差分を見る（AWS の今のスタックと比べる。変更はしない）
cdk diff -c config=config.yml "$STACK"

# 2. 反映する。すべての変更で確認を求め、y で反映する（既定は権限やセキュリティグループを広げる変更だけ確認する）
cdk deploy -c config=config.yml "$STACK" --require-approval any-change
#   <prefix>-step2-cloudfront（とオプションの C）の初回は次を足す
#   --parameters "$STACK:OriginVerifyHeaderValue=<秘密のヘッダーの値>"

# 3. 出力を見る（cdk deploy の最後にも出る。--outputs-file outputs.json でファイルにも書ける）
aws cloudformation describe-stacks --region <リージョン> --stack-name "$STACK" \
  --query 'Stacks[0].Outputs' --output table
```

- リージョンは、スタックの定義に書いてある（上の「出るスタック」の表）ので、`cdk deploy` には渡さない。アカウントは、使っている認証情報のものになる
- 変更セットを人に見せてから反映したいときは、`--method=prepare-change-set`（変更セットを作るだけ。名前の既定は `cdk-deploy-change-set`）で作り、`aws cloudformation describe-change-set` で見て、`--method=execute-change-set` で反映する
- スタックの名前はいつも渡す。`--all` は使わない（ステップの順と、設定値の書き足しの順を守るため）

### 方法 2: CloudFormation のテンプレート（YAML）を出して AWS CLI で反映する

**テンプレートを出す → 変更セットを作る → 中身を見る → 反映する** の順に行う。

```bash
source .venv/bin/activate
STACK=<スタック名>          # 例: myapp-production-step2-cloudfront
REGION=<リージョン>         # 上の「出るスタック」の表のリージョン

# 1. テンプレートを YAML で出す（cdk.out/ にも JSON が出る）
mkdir -p templates
cdk synth -c config=config.yml "$STACK" > "templates/$STACK.template.yml"
cfn-lint "templates/$STACK.template.yml"   # 別にインストールが必要

# 2. 変更セットを作る（反映はしない）
aws cloudformation deploy --region "$REGION" --no-execute-changeset \
  --template-file "templates/$STACK.template.yml" \
  --stack-name "$STACK"
#   <prefix>-step2-cloudfront（とオプションの C）の初回は次を足す
#   --parameter-overrides OriginVerifyHeaderValue=<秘密のヘッダーの値>

# 3. 中身を見る（2 の出力にも describe-change-set のコマンドが出る）
aws cloudformation list-change-sets --region "$REGION" --stack-name "$STACK"
aws cloudformation describe-change-set --region "$REGION" \
  --stack-name "$STACK" --change-set-name <変更セットの名前>

# 4. 反映して、終わるまで待つ
aws cloudformation execute-change-set --region "$REGION" \
  --stack-name "$STACK" --change-set-name <変更セットの名前>
aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$STACK"   # 更新なら stack-update-complete

# 5. 出力を見る
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query 'Stacks[0].Outputs' --output table
```

- `cdk` の CLI を入れないなら、1 の代わりに [合成](#合成)の 1 つ目の形で JSON を出し、2 の `--template-file` に `cdk.out/$STACK.template.json` を渡す。中身は YAML と同じ
- テンプレートが 51,200 バイトを超えると、`aws cloudformation deploy` に `--s3-bucket` が要る。本線のテンプレートはどれも 4 KB 未満、オプションの C で約 9 KB なので要らない（2026-11-13）。例外の IP を数百件並べると大きくなる（方法 1 でも、この大きさを超えるとブートストラップが要る）

## 3 つのステップでの使い方

確認の中身は各ステップのドキュメントにある。CDK で行うのは、スタックの合成とデプロイの部分だけ。デプロイは[方法 1・方法 2](#デプロイ)のどちらでもよい。

| # | ステップ | 行うこと | 確かめること |
|---|---|---|---|
| 1 | ステップ 1 | CloudFormation の YAML（`cloudformation/step1-certificate.yml`）か CDK のどちらか。CDK なら `<prefix>-step1-certificate` をデプロイする（`us-east-1`。ステージングは設定値 `certificate_hosted_zone_id` を書く）。出力の `CertificateArn` を設定値の `cloudfront_certificate_arn` に書く | [確認 1](../../step1-acm-certificate.md#確認-1ステップ-2-へ進む条件) |
| 2 | ステップ 2 | 設定値ファイルを作って合成する（`cloudfront_web_acl_arn` は空のまま） → `<prefix>-step2-waf` をデプロイ（`us-east-1`） → 出力の `WebAclArn` を設定値に書いて合成し直す → `<prefix>-step2-cloudfront` をデプロイ（`aws_region`。`OriginVerifyHeaderValue` を渡す） → 出力 `OriginSecurityGroupId` を稼働サーバーに足す | [確認 2](../../step2-cloudfront.md#確認-2ステップ-3-へ進む条件) |
| 3 | ステップ 3 | **CDK は使わない**。シェルスクリプト `scripts/step3-dns-switch.sh` で向き先を変える | [確認 3](../../step3-dns-switch.md#確認-3片付けへ進む条件) |

### オプション（採用しなかった構成）

- A. ALB → EC2: `option_stacks: [alb-to-ec2]` と `alb_certificate_arn` ほかを書いて合成し、`<prefix>-option-alb-to-ec2` をデプロイする。手順は [options/alb-to-ec2.md](../../options/alb-to-ec2.md)
- C. CloudFront → ALB → EC2: `option_stacks: [cloudfront-alb-to-ec2]` で `restrict_to_cloudfront: false` のまま合成・デプロイし、DNS を CloudFront へ向けて元の TTL が過ぎてから、`true` にして合成し直し、同じスタックを更新する。手順は [options/cloudfront-alb-to-ec2.md](../../options/cloudfront-alb-to-ec2.md)

## 撤去

逆の順（ステップ 2 の CloudFront → ステップ 2 の WAF → ステップ 1）に消す。

```bash
# 方法 1・2 のどちらで入れたスタックも、CloudFormation のスタックなので同じコマンドで消せる
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

AWS のドキュメントと照らし合わせた（2026-11-12、2026-11-13）。

- [cdk deploy（ブートストラップしていない環境はアセットがなく 51,200 バイト未満のスタックだけ、--parameters、--previous-parameters の既定、--method、--require-approval）](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-deploy.html)（2026-11-13）
- [cdk synth（スタックが 1 つなら YAML を標準出力に出す、--quiet）](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-synth.html)（2026-11-13）
- [AWS CDK bootstrapping（作るもの、環境ごと）](https://docs.aws.amazon.com/cdk/v2/guide/bootstrapping.html)（2026-11-13）
- AWS CLI 2.40.0 の `aws cloudformation deploy help`（更新で渡さなかったパラメータは今の値を使う。2026-11-13）
- [ACME certificate automation（ACME 証明書は ELB・CloudFront に付けられない、45 日、秘密鍵と更新は ACME クライアント）](https://docs.aws.amazon.com/acm/latest/userguide/acm-acme.html)
- [AWS Certificate Manager Pricing](https://aws.amazon.com/certificate-manager/pricing/)
- [AWS Certificate Manager now supports the ACME protocol for public certificates（2026-07 の発表）](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-certificate-manager-acme/)
- [aws cloudformation deploy](https://docs.aws.amazon.com/cli/latest/reference/cloudformation/deploy/)
- 定義の側の参考は [definitions.md の参考](../../definitions.md#参考)
