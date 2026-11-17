# ステップ 4: オリジンへの接続の制限（後付け）

> 位置付け: B. CloudFront → EC2 への移行の最後のステップ。ステップ 3 で利用者の接続が CloudFront を通るようになった後に、稼働サーバーへの接続を CloudFront だけに絞り、残りを片付ける。ルーティングを先に作るため、この制限はステップ 2 から分けて後から付ける（[README の T15](./README.md#決めたこと)）。前は [ステップ 3: 向き先の変更](./step3-dns-switch.md)。全体は [README](./README.md#ステップの流れ)。
>
> 確かめた範囲: セキュリティグループと CloudFront のプレフィックスリストの仕様は AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-11）。httpd の設定は今の構成に近いコンテナで確かめた（2026-11-10）。**AWS のコマンドは実行しておらず、実際の稼働サーバーでは試していない**。`app.example.com`・`203.0.113.10` は例で、`<...>` は環境に合わせて置き換える。
>
> 作成日: 2026-11-17（ステップ 2 の 2-3 と、ステップ 3 の片付けから集めた）

## 用語

[README の用語](./README.md#用語)に加えて、次の語を使う。

| 用語 | 指すもの |
|---|---|
| 全公開の許可 | 稼働サーバーの今のセキュリティグループにある、`0.0.0.0/0`（と `::/0`）からの 80・443 番の許可 |
| オリジン用のセキュリティグループ | CloudFront のオリジン向けのアドレスの一覧（プレフィックスリスト `com.amazonaws.global.cloudfront.origin-facing`）から 443 番だけを許可するグループ。このステップのスタック `<prefix>-step4-origin-sg` が作る |
| 直接の接続 | CloudFront を通らずに、稼働サーバーの Elastic IP へ来る接続 |

## このステップの結果

- 稼働サーバーの 80・443 番に届くのは、CloudFront（と踏み台サーバーからの 443 番）だけになる
- CloudFront を通らない要求は、httpd が秘密のヘッダーで断る（CloudFront のプレフィックスリストは CloudFront 全体の範囲で、他人のディストリビューションからも届くため）
- Let's Encrypt の更新は、CloudFront を通る経路で続く

## 始める前に

| 条件 | 内容 |
|---|---|
| ステップ 3 が済んでいる | [確認 3](./step3-dns-switch.md#確認-3ステップ-4-へ進む条件) を通り、元の TTL より長く待った（[3-4](./step3-dns-switch.md#3-4-待つ)） |
| IP で直接つないでいる相手がいない | Elastic IP を指定して呼んでいる相手は、このステップで止まる。[README の共通の確認](./README.md#どの手順でも共通して確かめること)のとおり、先に洗い出して名前での接続に移してもらう |
| 秘密のヘッダーの値 | [準備の 4](./step0-preparation.md#4-秘密のヘッダーの値を作る) で作り、ステップ 2 で CloudFront に渡した値 |

## 行うこと

端末で行うのは変更セットを作るところまでで、中身の確認と実行は AWS のコンソールで行う（[変更セットをコンソールで実行する](./definitions.md#変更セットをコンソールで実行する)。[README の T11](./README.md#決めたこと)）。セキュリティグループの付け替えと、今のグループの許可の削除は CloudFormation の外なので、AWS CLI で行う。

| # | 行うこと | 道具 | 利用者への影響 |
|---|---|---|---|
| 4-1 | オリジン用のセキュリティグループを作る | CDK `<prefix>-step4-origin-sg`（`ap-northeast-1`） | なし |
| 4-2 | オリジン用のセキュリティグループを稼働サーバーに**足す** | AWS CLI | なし |
| 4-3 | httpd で秘密のヘッダーを確かめる | 稼働サーバーの httpd | 直接の接続が 403 になる |
| 4-4 | 今のセキュリティグループから全公開の許可を消す | AWS CLI | 直接の接続が届かなくなる |
| 確認 4 | 直接の接続が届かず、CloudFront 経由と証明書の更新は通ることを確かめる | — | なし |
| 片付け | TTL を戻す、証明書の監視、控えのファイル | — | なし |

## 4-1. オリジン用のセキュリティグループを作る

設定値ファイル（[ステップ 1.5 の 1.5-0](./step1-5-waf.md#15-0-cdk-の準備と設定値ファイル)）の `vpc_id`・`cloudfront_prefix_list_id` を使う。ほかのスタックの出力は使わない。

```bash
cd cdk/python && source .venv/bin/activate

# 方法 1: CDK で変更セットを作る
cdk diff   -c config=config.yml <prefix>-step4-origin-sg
cdk deploy -c config=config.yml <prefix>-step4-origin-sg --method=prepare-change-set

# 方法 2: CloudFormation のテンプレート（YAML）を出して、AWS CLI で変更セットを作る
cdk synth -c config=config.yml <prefix>-step4-origin-sg > templates/<prefix>-step4-origin-sg.template.yml
aws cloudformation deploy --region ap-northeast-1 --no-execute-changeset \
  --template-file templates/<prefix>-step4-origin-sg.template.yml --stack-name <prefix>-step4-origin-sg

# どちらの方法でも、この後、コンソール（ap-northeast-1）で変更セットを確かめて実行する。
# CREATE_COMPLETE になってから、出力の OriginSecurityGroupId を見る（コンソールの「出力」のタブでもよい）
aws cloudformation describe-stacks --region ap-northeast-1 --stack-name <prefix>-step4-origin-sg \
  --query "Stacks[0].Outputs[?OutputKey=='OriginSecurityGroupId'].OutputValue" --output text
```

CloudFront のプレフィックスリストは、セキュリティグループの規則の上限で 55 件分に数える。既存のグループに足すと上限（既定 60 件）を超えやすいので、専用のグループにしている。

## 4-2. オリジン用のセキュリティグループを稼働サーバーに足す

4-1 の `OriginSecurityGroupId` を、稼働サーバーに**足す**。`modify-instance-attribute --groups` は全部を置き換えるので、今のグループも並べる。

```bash
aws ec2 describe-instances --region ap-northeast-1 --instance-ids <インスタンス ID> \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text
aws ec2 modify-instance-attribute --region ap-northeast-1 --instance-id <インスタンス ID> \
  --groups <今のグループ…> <OriginSecurityGroupId>
```

この時点では、全公開の許可も残っているので、利用者への影響はない。

## 4-3. httpd で秘密のヘッダーを確かめる

稼働サーバーの httpd に、[秘密のヘッダーの確認](./cloudfront-to-ec2-httpd.md#3-秘密のヘッダーを確認する)を入れる（準備の 4 で作った値）。

```bash
sudo apachectl configtest
sudo apachectl graceful

# CloudFront を通らない接続（Elastic IP へ直接）は 403
curl -sI --resolve app.example.com:443:<Elastic IP> https://app.example.com/
# CloudFront を通る接続はアプリの応答
curl -sI https://app.example.com/
```

## 4-4. 今のセキュリティグループから全公開の許可を消す

稼働サーバーの今のグループから、`0.0.0.0/0`（と `::/0`）の 80・443 番の許可を消す。**踏み台サーバーからの 443 番の許可は残す**（オリジンの証明書の残り日数を、踏み台サーバーから確かめるため）。80 番は、CloudFront からも使わないので開けない（CloudFront は 443 番にだけ接続する。Let's Encrypt の確認も CloudFront を通って 443 番に届く）。

```bash
# 今の許可を見る
aws ec2 describe-security-groups --region ap-northeast-1 --group-ids <今のグループ> \
  --query 'SecurityGroups[0].IpPermissions'

# 全公開の許可を消す（あるものだけ。::/0 は Ipv6Ranges で同じように消す）
aws ec2 revoke-security-group-ingress --region ap-northeast-1 --group-id <今のグループ> \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' \
                   'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]'
```

消す前に、`describe-security-groups` の結果を控えておく（[元に戻す](#元に戻す)ときに使う）。

## 確認 4（片付けへ進む条件）

| 確認 | コマンド・見るところ | 期待 |
|---|---|---|
| 直接の接続 | 手元から `curl -sI --connect-timeout 5 --resolve app.example.com:443:<Elastic IP> https://app.example.com/` | 届かない（時間切れ） |
| CloudFront 経由 | `curl -sI https://app.example.com/` | アプリの応答。`Via` に `cloudfront.net` |
| 証明書の更新 | 稼働サーバーで `sudo certbot renew --dry-run` | 成功（CloudFront と WAF を通る経路で確認が届く） |
| 踏み台サーバーからの確認 | 踏み台サーバーから稼働サーバーの 443 番へ接続（[残り日数の確かめ方](./cloudfront-to-ec2-domains-certificates.md#残り日数の確かめ方)） | 証明書の期限が読める |
| エラーの割合 | CloudFront の 4xx・5xx の割合（CloudWatch のメトリクス） | 増えていない |

502 が出るなら、オリジン用のセキュリティグループが稼働サーバーに付いているか（4-2）を見る。

## 片付け

| 順番 | 作業 | 確かめ方 |
|---|---|---|
| 1 | 証明書の残り日数の監視を入れる。**オリジンの証明書が切れると、すべての利用者に 502 が返る** | [残り日数の確かめ方](./cloudfront-to-ec2-domains-certificates.md#残り日数の確かめ方) |
| 2 | 本番の CNAME の TTL を元に戻す（Route 53 のエイリアスのレコードは TTL を持たない） | `dig app.example.com` |
| 3 | （オプションの WAF のマネージドルールを入れるときだけ）count で入れて誤検知を確かめてから `block` にする。既定の WAF には入れていない | [options/waf-managed-rules.md の入れ方](./options/waf-managed-rules.md#入れ方方法論) |
| 4 | ステップ 3 の控えのファイルを片付ける（戻す見込みがなくなってから） | |

## 元に戻す

逆の順で戻す。DNS も戻すなら、ここを戻してから [ステップ 3 の元に戻す](./step3-dns-switch.md#元に戻す)。

1. 4-4 で消した全公開の許可を足し直す（控えた結果のとおりに `aws ec2 authorize-security-group-ingress`）
2. httpd の秘密のヘッダーの確認を外して、`apachectl graceful`
3. 稼働サーバーから `OriginSecurityGroupId` を外す（`modify-instance-attribute --groups <今のグループ…>`。付けたままだとグループを消せず、スタックの削除が失敗する）
4. コンソール（`ap-northeast-1`）で `<prefix>-step4-origin-sg` を消す

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-11）。

- [Locations and IP address ranges of CloudFront edge servers（origin-facing のプレフィックスリスト）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html)
- [AWS-managed prefix lists（weight）](https://docs.aws.amazon.com/vpc/latest/userguide/working-with-aws-managed-prefix-lists.html)
- [Add custom headers to origin requests（秘密のヘッダー）](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/add-origin-custom-headers.html)
- [Challenge types（Let's Encrypt の HTTP-01 は 80・443 番へのリダイレクトをたどる）](https://letsencrypt.org/docs/challenge-types/)（2026-11-17）
