# ステップ 1: ACM の証明書

> 位置付け: B. CloudFront → EC2 への移行の 3 つのステップの 1 つ目。CloudFront の証明書（利用者と CloudFront の間で使う証明書）を、ACM の `us-east-1` に用意する。前は [準備](./step0-preparation.md)、次は [ステップ 2: CloudFront のルーティング](./step2-cloudfront.md)。全体は [README](./README.md#3-つのステップ)。
>
> 確かめた範囲: ACM・CloudFormation の仕様は AWS のドキュメントと照らし合わせた（2026-11-11、2026-11-12）。定義は `cfn-lint` まで確かめた（2026-11-12）。**AWS のコマンドは実行しておらず、外部の DNS サービスでも試していない**。`app.example.com` は例で、`<...>` は環境に合わせて置き換える。
>
> 作成日: 2026-11-12（`external-dns-certificate.md` と `definitions.md` から集めた）

## 用語

[README の用語](./README.md#用語)に加えて、次の語を使う。

| 用語 | 指すもの |
|---|---|
| 作成 | ACM に新しい証明書を発行してもらうこと（`RequestCertificate`。DNS 検証） |
| 登録 | ACM の外で手に入れた証明書を、ACM に取り込むこと（`ImportCertificate`。インポート） |
| 検証用の CNAME | ACM が示す `_<文字列>.app.example.com` → `_<文字列>.acm-validations.aws.` のレコード。ドメインを持っていることの証明と、自動更新に使う |
| 外部の DNS サービス | `example.com` のゾーン（DNS のレコード）を管理している Route 53 以外のサービス。レジストラ（ドメインを買った先）と同じとは限らない |

## このステップの結果

- `us-east-1` の ACM に、利用者のドメイン名（`app.example.com`）を含む証明書があり、状態が `ISSUED`
- その ARN を、ステップ 2 の CloudFront のスタックに渡せる
- 利用者への影響はない（まだどこにも付けていない）

## 証明書の用意の仕方

| 方法 | 内容 | 更新 | 定義 |
|---|---|---|---|
| **1-A. ACM で作成する（採用）** | ACM に申請し、DNS 検証で発行してもらう | **ACM が自動で行う**（検証用の CNAME を残し、証明書が使われている間） | **CloudFormation の `step1-certificate.yml`** |
| 1-B. 既存の証明書を ACM に登録する（オプション） | 手元の証明書と秘密鍵を `import-certificate` で取り込む | **ACM は自動で更新しない**。期限の前に新しい証明書を入れ直す | なし（CloudFormation は登録に対応していない。AWS CLI で行う） |

1-A を使う（[README の T6](./README.md#決めたこと)）。**定義は CloudFormation の YAML で扱う**（リソースが証明書 1 つだけで、CDK を使うほどの量がないため。[README の T9](./README.md#決めたこと)）。同じ内容の CDK のスタック（`<prefix>-step1-certificate`）もあるが、この手順では使わない。1-B は、ACM で作成できない事情（CAA を変えられないなど）があるときのために[別の節](#1-b-既存の証明書を登録するオプション)に書いた。

### 証明書の種類

ACM のコンソールには「**証明書**」と「**ACME 証明書**」がある。**CloudFront に付けるのは「証明書」**で、1-A でも 1-B でも、できるのはこちらである。「ACME 証明書」は CloudFront・ALB に付けられない（AWS のドキュメントに明記）。違いは [cdk/python/README.md の「ACM の証明書の種類」](./cdk/python/README.md#acm-の証明書の種類)にまとめた。

## 1-A. ACM で作成する（採用）

CloudFront に付ける証明書は **`us-east-1`** に作る（CloudFront の決まり）。ステージングと本番で、検証用の CNAME の足し方だけが違う。

| | ステージング（Route 53） | 本番（外部の DNS サービス） |
|---|---|---|
| パラメータ `HostedZoneId` | `app.example.com` のホストゾーン ID | 空 |
| 検証用の CNAME | CloudFormation が自動で作る | **手で足す** |
| スタックの作成 | 数分で終わる見込み | CNAME を足して検証が済むまで `CREATE_IN_PROGRESS` のまま待つ |

### 1-A-1. Route 53（ステージング）

```bash
aws cloudformation deploy --region us-east-1 \
  --template-file cloudformation/step1-certificate.yml \
  --stack-name <prefix>-step1-certificate \
  --parameter-overrides DomainName=app.example.com HostedZoneId=<ホストゾーン ID>
```

### 1-A-2. 外部の DNS サービス（本番）

**ACM が CNAME を示してから 72 時間以内に検証できないと、証明書は `Validation timed out` になり、申請し直しになる**（ACM のドキュメントの記述）。CNAME を足すのを人に頼むなら、72 時間以内に足してもらえる段取りを先に付けてから始める。

1. `HostedZoneId` を空にしてスタックを作る。スタックは検証が済むまで戻ってこないので、2 は別の端末で行う。

   ```bash
   aws cloudformation deploy --region us-east-1 \
     --template-file cloudformation/step1-certificate.yml \
     --stack-name <prefix>-step1-certificate \
     --parameter-overrides DomainName=app.example.com
   ```

2. 足すレコードを取り出す。申請の直後は `ResourceRecord` がまだ空のことがある見込みで、その場合は少し待って流し直す（確かめていない）。

   ```bash
   aws acm list-certificates --region us-east-1 \
     --certificate-statuses PENDING_VALIDATION \
     --query "CertificateSummaryList[?DomainName=='app.example.com'].CertificateArn" --output text

   aws acm describe-certificate --region us-east-1 --certificate-arn <ARN> \
     --query 'Certificate.DomainValidationOptions[].ResourceRecord'
   ```

3. 外部の DNS サービスに足す。TTL は既定のままでよい。

   | 名前 | 種類 | 値 |
   |---|---|---|
   | `_<文字列>.app.example.com.` | CNAME | `_<文字列>.acm-validations.aws.` |

   | 注意 | 内容 |
   |---|---|
   | 名前の欄の入力の仕方 | サービスによって、名前を `_<文字列>.app.example.com.` と完全な形で入れるものと、`_<文字列>.app` のようにゾーンの名前を自動で付け足すものがある。間違えると `..example.com.example.com.` になり、検証が失敗する（ACM のドキュメントの注意） |
   | 先頭の `_` | 先頭が `_` の名前を受け付けないサービスがある（ACM のドキュメントの注意。その場合は ACM のトラブルシューティングを見る） |
   | **このレコードは消さない** | ACM は、証明書が使われていて、このレコードが残っている間、自動で更新する。消すと自動更新が止まる。DNS サービスを移すときも一緒に移す |

4. 引けるようになったかを確かめる。

   ```bash
   dig +short CNAME _<文字列>.app.example.com
   ```

72 時間を過ぎて `Validation timed out` になったら、スタックを消して 1 からやり直す。

## 1-B. 既存の証明書を登録する（オプション）

手元にある証明書を ACM に取り込む。**ACM は登録した証明書を自動で更新しない**ので、期限の前に新しい証明書を手に入れ、同じ ARN へ入れ直す（再インポート）必要がある。期限の監視も自分で行う。Let's Encrypt の証明書（有効期間 90 日）を登録すると、更新のたびに入れ直しが要るので勧めない。

| 条件 | 内容 |
|---|---|
| リージョン | **`us-east-1`**（CloudFront で使うため） |
| 形式 | 証明書・秘密鍵・中間証明書のすべてが PEM。秘密鍵は**暗号化しない**形で、5 KB 以下 |
| 鍵の種類 | CloudFront で使えるのは RSA（1024・2048・3072・4096 ビット）と ECDSA の P-256 だけ |
| 有効期間 | 登録する時点で有効なこと（期限切れや、開始前のものは登録できない） |
| 名前 | 利用者のドメイン名（`app.example.com`）を含むこと |

```bash
# 新しく登録する
aws acm import-certificate --region us-east-1 \
  --certificate fileb://cert.pem \
  --private-key fileb://privkey.pem \
  --certificate-chain fileb://chain.pem

# 更新した証明書を、同じ ARN へ入れ直す（CloudFront との関連付けと ARN が保たれる）
aws acm import-certificate --region us-east-1 \
  --certificate-arn <ARN> \
  --certificate fileb://cert.pem \
  --private-key fileb://privkey.pem \
  --certificate-chain fileb://chain.pem
```

秘密鍵を手元の端末へ持ち出すことになるので、作業の後に消す。登録した証明書の残り日数は、ACM の `DaysToExpiry`（CloudWatch のメトリクス）か、EventBridge の期限の通知で見る。

## 確認 1（ステップ 2 へ進む条件）

```bash
aws acm describe-certificate --region us-east-1 --certificate-arn <ARN> \
  --query 'Certificate.{Status:Status,Domain:DomainName,Names:SubjectAlternativeNames,Type:Type,NotAfter:NotAfter,InUseBy:InUseBy}'

# 1-A の場合。スタックの出力の ARN
aws cloudformation describe-stacks --region us-east-1 --stack-name <prefix>-step1-certificate \
  --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" --output text
```

| 確認 | 期待 |
|---|---|
| `Status` | `ISSUED` |
| リージョン | `us-east-1`（ARN が `arn:aws:acm:us-east-1:` で始まる） |
| `DomainName`・`SubjectAlternativeNames` | `app.example.com` を含む |
| `Type` | 1-A は `AMAZON_ISSUED`、1-B は `IMPORTED` |
| `NotAfter` | 1-B は、十分先であること |
| 検証用の CNAME（1-A） | `dig +short CNAME _<文字列>.app.example.com` で引ける（残しておく） |
| スタック（1-A） | `CREATE_COMPLETE` |

ARN を控える。ステップ 2（CDK）の設定値の `cloudfront_certificate_arn` に書く。

## 元に戻す

利用者への影響はない。1-A はスタックを消す（`aws cloudformation delete-stack --region us-east-1 --stack-name <prefix>-step1-certificate`）。1-B は `aws acm delete-certificate --region us-east-1 --certificate-arn <ARN>`。どちらも、CloudFront に付けた後（ステップ 2 の後）は、先に CloudFront のスタックを消さないと消せない。外部の DNS サービスに足した検証用の CNAME は、作り直す見込みがなければ消す。

## 参考

AWS のドキュメントと照らし合わせた（2026-11-11、2026-11-12）。

- [AWS Certificate Manager DNS validation（外部の DNS での CNAME の足し方、名前の欄の注意、CNAME を残すと自動更新、72 時間で Validation timed out）](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html)
- [AWS::CertificateManager::Certificate（Route 53 での自動検証、Route 53 にないドメインは CREATE_IN_PROGRESS のまま待つ）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-certificatemanager-certificate.html)
- [Requirements for using SSL/TLS certificates with CloudFront（us-east-1）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html)
- [Import certificates into AWS Certificate Manager（登録した証明書は自動で更新されない、CloudFront は us-east-1、再インポートで ARN を保つ）](https://docs.aws.amazon.com/acm/latest/userguide/import-certificate.html)（2026-11-12）
- [Prerequisites for importing ACM certificates（PEM、暗号化しない秘密鍵、CloudFront の鍵の種類、CloudFormation は登録に対応しない）](https://docs.aws.amazon.com/acm/latest/userguide/import-certificate-prerequisites.html)（2026-11-12）
- [ACME certificate automation（ACME 証明書は CloudFront に付けられない）](https://docs.aws.amazon.com/acm/latest/userguide/acm-acme.html)（2026-11-12）
- [Supported CloudWatch metrics（ACM の DaysToExpiry）](https://docs.aws.amazon.com/acm/latest/userguide/cloudwatch-metrics.html)
