# ステップ 1.5: WAF の web ACL

> 位置付け: B. CloudFront → EC2 への移行の、ステップ 1 とステップ 2 の間に置くステップ。CloudFront に付ける AWS WAF の web ACL（国の絞り込み）を、`us-east-1` に用意する。**ステップ 2 の CloudFront より前に作る**（CloudFront の作成のときに web ACL の ARN を渡すため）。**WAF を使わないなら省略できる**（[省略する場合](#省略する場合)）。前は [ステップ 1: ACM の証明書](./step1-acm-certificate.md)、次は [ステップ 2: CloudFront のルーティング](./step2-cloudfront.md)。全体は [README](./README.md#3-つのステップ)。
>
> 確かめた範囲: AWS WAF の仕様は AWS のドキュメントと照らし合わせた（2026-11-11、2026-11-13）。定義は CDK の合成と `cfn-lint` まで確かめた（2026-11-16）。**AWS のコマンドと `cdk deploy` は実行しておらず、実際の WAF では試していない**。`<...>` は環境に合わせて置き換える。
>
> 作成日: 2026-11-16（ステップ 2 の 2-0・2-1 から分けた）

## 用語

[README の用語](./README.md#用語)に加えて、次の語を使う。

| 用語 | 指すもの |
|---|---|
| web ACL | AWS WAF のルールの集まり。CloudFront に関連付けると、CloudFront に来た要求をルールで見て、通すか止める |
| 例外の IP | 許可する国の外からでも通す IP アドレス（CIDR）。海外の拠点や外部の監視などのため |

## このステップの結果

- `us-east-1` に web ACL（`<prefix>-step1-5-waf`）があり、その ARN（出力 `WebAclArn`）を設定値の `cloudfront_web_acl_arn` に書いてある
- まだ CloudFront に付けていないので、**利用者への影響はない**（効き始めるのはステップ 2 で CloudFront に関連付けてから）

## ステップの順番

| 前後 | 関係 |
|---|---|
| ステップ 1（証明書）との関係 | **ない**。どちらも `us-east-1` に作るが、互いの出力を使わない。ステップ 1 と並べて行ってもよい |
| ステップ 2（CloudFront）との関係 | **先に作る**。ステップ 2 の CloudFront のスタックが、このステップの `WebAclArn` を受け取る |
| WAF が効いているかの確認 | CloudFront を通さないと確かめられないので、[ステップ 2 の確認 2](./step2-cloudfront.md#確認-2ステップ-3-へ進む条件)で行う。このステップの確認は、web ACL ができて ARN が取れることまで |

## 省略する場合

WAF を使わない（国で絞らない）なら、このステップを飛ばし、設定値の `cloudfront_web_acl_arn` を空のままステップ 2 へ進む。CloudFront は web ACL なしで作られる。後から WAF を足すときは、このステップを行い、`cloudfront_web_acl_arn` を書いてステップ 2 の CloudFront のスタックを更新する。**本番では省略しない**（[README の結論](./README.md#結論)のとおり、この移行の目的は WAF による防御）。

## 行うこと

**定義は CDK で扱う**（[README の T9](./README.md#決めたこと)）。端末で行うのは変更セットを作るところまでで、中身の確認と実行は AWS のコンソールで行う（[変更セットをコンソールで実行する](./definitions.md#変更セットをコンソールで実行する)。[README の T11](./README.md#決めたこと)）。同じ内容の CloudFormation の YAML（`cloudformation/step1-5-waf.yml`）もあるが、この手順では使わない。

| # | 行うこと | リージョン | CDK のスタック |
|---|---|---|---|
| 1.5-0 | CDK の準備と設定値ファイル | — | — |
| 1.5-1 | WAF の web ACL を作る | `us-east-1` | `<prefix>-step1-5-waf` |
| 確認 1.5 | web ACL ができたことを確かめる | `us-east-1` | — |

## 1.5-0. CDK の準備と設定値ファイル

準備（venv、`pip install`。`aws-cdk-lib` の取得は約 60 MB）は [cdk/python/README.md の準備](./cdk/python/README.md#準備)。設定値ファイルを作り、ステップ 1.5 とステップ 2 の項目を書く（ステップ 1 を CDK で行ったなら、そのときの設定値ファイルに書き足す）。

```bash
cd cdk/python
cp config.example.yml config.yml
```

| 設定値 | 値 |
|---|---|
| `stack_name_prefix`、`aws_region`、`vpc_id`、`availability_zones`、`cloudfront_prefix_list_id` | 環境の値（プレフィックスリストの ID は下のコマンドで調べる） |
| `domain_name`、`origin_domain_name` | `app.example.com`、`origin.app.example.com` |
| `cloudfront_certificate_arn` | **ステップ 1 の `CertificateArn`** |
| `cloudfront_web_acl_arn` | 1.5-1 の後に書く（それまでは空。WAF を使わないなら空のまま） |
| `origin_hosted_zone_id`、`origin_elastic_ip` | ステージングだけ（[ステップ 2 の 2-1](./step2-cloudfront.md#2-1-オリジンの名前)） |
| `waf_*` | 1.5-1 の表 |

```bash
aws ec2 describe-managed-prefix-lists --region ap-northeast-1 \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text
```

変更セットの作り方は 2 通りあり、どのスタックも同じ形で行う（詳しくは [cdk/python/README.md のデプロイ](./cdk/python/README.md#デプロイ)）。どちらも `cdk/python/` で、venv を有効にしてから流す。作った変更セットは、どちらもコンソールで確かめて実行する（[変更セットをコンソールで実行する](./definitions.md#変更セットをコンソールで実行する)）。

| | 方法 1: CDK で変更セットを作る | 方法 2: CDK から CloudFormation のテンプレート（YAML）を出し、AWS CLI で変更セットを作る |
|---|---|---|
| 変更の中身を見る | 端末の `cdk diff` と、コンソールの変更セット | コンソールの変更セット |
| 反映したテンプレート | 手元に残すことは考えない（`cdk.out/` は合成のたびに上書き） | `templates/<スタック名>.template.yml` に残る。`cfn-lint` にかけたり、人に渡したりできる |
| 秘密のヘッダーの値 | `--parameters <スタック名>:OriginVerifyHeaderValue=<値>` | `--parameter-overrides OriginVerifyHeaderValue=<値>` |

```bash
source .venv/bin/activate

# 方法 1: CDK で変更セットを作る
cdk diff   -c config=config.yml <スタック名>
cdk deploy -c config=config.yml <スタック名> --method=prepare-change-set [--parameters ...]

# 方法 2: CloudFormation のテンプレート（YAML）を出して、AWS CLI で変更セットを作る
mkdir -p templates
cdk synth -c config=config.yml <スタック名> > templates/<スタック名>.template.yml
aws cloudformation deploy --region <リージョン> --no-execute-changeset \
  --template-file templates/<スタック名>.template.yml --stack-name <スタック名> [--parameter-overrides ...]

# どちらの方法でも、この後、コンソールで変更セットを確かめて実行する
```

- `cdk` の CLI を入れないときは、方法 2 で JSON のテンプレートを使う（`CDK_CONTEXT_JSON='{"config":"config.yml"}' CDK_OUTDIR=cdk.out .venv/bin/python app.py` で合成し、`--template-file cdk.out/<スタック名>.template.json` を渡す）
- 合成すると、ステップ 1 の CDK のスタック（`<prefix>-step1-certificate`）のテンプレートも出る。ステップ 1 を CloudFormation の YAML で済ませたなら使わない。`<スタック名>` を指定して流すので、ステップ 1 のスタックが反映し直されることはない

## 1.5-1. WAF の web ACL

国の絞り込み（既定は `JP` だけ）と例外の IP だけを持つ web ACL を作る。`/.well-known/acme-challenge/` だけはどの国からも通す（オリジンの証明書を HTTP-01 で更新し続けるため）。ルールの中身は [definitions.md の WAF](./definitions.md#ステップ-15-の-waf国の絞り込み)。AWS のマネージドルールとログは既定では入れない（入れるなら [options/waf-managed-rules.md](./options/waf-managed-rules.md)。[README の T10](./README.md#決めたこと)）。

| 決めること | 既定 | 内容 |
|---|---|---|
| 許可する国 | `JP` | 設定値 `waf_allowed_countries` |
| 例外の IP | なし | 設定値 `waf_exception_ipv4_addresses`・`waf_exception_ipv6_addresses`。海外から使う相手がいれば CIDR で足す |

1.5-0 のどちらかの方法で `us-east-1` に変更セットを作り、コンソールで実行する（パラメータはない。方法 1 のリージョンはスタックの定義に書いてある）。

```bash
# 方法 1: CDK で変更セットを作る
cdk diff   -c config=config.yml <prefix>-step1-5-waf
cdk deploy -c config=config.yml <prefix>-step1-5-waf --method=prepare-change-set

# 方法 2: CloudFormation のテンプレート（YAML）を出して、AWS CLI で変更セットを作る
cdk synth -c config=config.yml <prefix>-step1-5-waf > templates/<prefix>-step1-5-waf.template.yml
aws cloudformation deploy --region us-east-1 --no-execute-changeset \
  --template-file templates/<prefix>-step1-5-waf.template.yml --stack-name <prefix>-step1-5-waf

# コンソール（us-east-1）で変更セットを確かめて実行し、CREATE_COMPLETE になってから、出力の WebAclArn を見る
# （コンソールの「出力」のタブでもよい）
aws cloudformation describe-stacks --region us-east-1 --stack-name <prefix>-step1-5-waf \
  --query "Stacks[0].Outputs[?OutputKey=='WebAclArn'].OutputValue" --output text
```

出力の `WebAclArn` を、設定値の `cloudfront_web_acl_arn` に書く（ステップ 2 で CloudFront に関連付ける）。

## 確認 1.5（ステップ 2 へ進む条件）

```bash
# スタックの状態と出力
aws cloudformation describe-stacks --region us-east-1 --stack-name <prefix>-step1-5-waf \
  --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}'

# web ACL のルール（名前と優先順位）
aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 \
  --name <prefix>-step1-5-waf --id <WebAclArn の最後の ID> \
  --query 'WebACL.Rules[].{Name:Name,Priority:Priority}'
```

| 確認 | 期待 |
|---|---|
| スタック | `<prefix>-step1-5-waf` が `CREATE_COMPLETE`（`us-east-1`） |
| ルール | `AllowAcmeChallenge`（0）と `BlockOutsideAllowedCountries`（1） |
| 設定値 | `cloudfront_web_acl_arn` に `WebAclArn` を書いた |

国の絞り込みが効いているかは、ステップ 2 で CloudFront に付けた後の[確認 2](./step2-cloudfront.md#確認-2ステップ-3-へ進む条件)で確かめる。

## 元に戻す

利用者への影響はない。コンソール（`us-east-1`）で `<prefix>-step1-5-waf` を消す。ステップ 2 の CloudFront に関連付けた後は、先に CloudFront から外す（CloudFront のスタックを消すか、`cloudfront_web_acl_arn` を空にして更新する）。使われている間は消せない。

## 参考

AWS のドキュメントと照らし合わせた。WAF のルールの参考は [definitions.md の参考](./definitions.md#参考)、変更セットの実行の参考は [definitions.md の使い方](./definitions.md#変更セットをコンソールで実行する)。

- [AWS::WAFv2::WebACL（CLOUDFRONT は us-east-1 に作る）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-wafv2-webacl.html)
- [Geographic match rule statement（地理的制限で止めた要求は WAF に届かない）](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-geo-match.html)（2026-11-11）
