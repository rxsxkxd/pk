# SSL/TLS の終端を EC2 の httpd から CloudFront へ移す

> 位置付け: 検討と手順の下書き。今 EC2 の httpd（Apache）が SSL/TLS を終端している Web サービスの前に CloudFront を置き、利用者から見た SSL/TLS の終端を CloudFront へ移す。構成は **B. CloudFront → EC2** でほぼ確定している（2026-11-11）。移行は 3 つのステップ（証明書 → CloudFront → DNS）を軸にし、ステップの間で設定が正常かを確かめてから次へ進む。WAF は、ステップ 1 と 2 の間のステップ 1.5 として、CloudFront より前に作る（使わないなら省略できる）。稼働サーバーへの接続を CloudFront だけに絞るのは、ルーティングができた後のステップ 4 として後から付ける（今の稼働サーバーは 80・443 番を全公開しているので、絞らなくても CloudFront から届く）。
>
> 確かめた範囲: AWS の仕様は AWS のドキュメントと照らし合わせた（2026-11-09〜2026-11-12）。Apache の設定は、今の構成に近いコンテナで確かめた（2026-11-10）。定義（CloudFormation の YAML と CDK）は `cfn-lint` と合成まで（`cdk` の CLI の `cdk synth` も 2026-11-13 に確かめた）、ステップ 3 のシェルスクリプトは構文の確認まで確かめた（2026-11-12）。**AWS のコマンドは実行しておらず、実際の CloudFront・ACM・Route 53 では試していない**。
>
> 関連: [前に置くときの国での絞り込み](../ec2/notes/ec2-operations/access-restriction-alb-cloudfront.md)、[稼働サーバーの前に置く構成と料金の考え方](../ec2/notes/instance-provisioning/cloudfront-alb-front-options.md)、[Let's Encrypt の扱い](../ec2/notes/instance-provisioning/letsencrypt-certificate-timing.md)
>
> 作成日: 2026-11-09（3 ステップの形に書き直した: 2026-11-12）

## 用語

| 用語 | 指すもの |
|---|---|
| 稼働サーバー | 今 SSL/TLS を終端している EC2 のインスタンス（httpd）。移行の後は CloudFront の接続先（オリジン）になる |
| 利用者のドメイン名 | 利用者が使う名前（例 `app.example.com`）。移行の前後で変わらない |
| オリジンの名前 | CloudFront が稼働サーバーへ接続するときに引く名前。**稼働サーバーの EC2 のパブリック DNS 名**（例 `ec2-203-0-113-10.ap-northeast-1.compute.amazonaws.com`。Elastic IP を返す）を使う（[T13](#決めたこと)） |
| CloudFront の証明書 | 利用者と CloudFront の間で使う証明書。ACM の `us-east-1` に置く。ACM のコンソールの「**証明書**」に出るもので、「ACME 証明書」ではない（[ステップ 1](./step1-acm-certificate.md#証明書の種類)） |
| オリジンの証明書 | CloudFront と稼働サーバーの間で使う証明書。今の Let's Encrypt の証明書を使い続ける |
| 秘密のヘッダー | CloudFront がオリジンへの要求に付けるヘッダー（`X-Origin-Verify`）。稼働サーバーの httpd が値を確かめ、CloudFront を通らない要求を止める |
| 稼働サーバーの前に置くサービス | 利用者と稼働サーバーの間に置く CloudFront や ALB。このドキュメント群では「前段」とは書かず、この言い方をする |
| 本線 | 採用した構成（B. CloudFront → EC2）の手順と定義 |
| オプション | 採用しなかった構成（ALB を使う構成）と、既定に入れなかった設定（WAF のマネージドルールとログ）の手順と定義。`options/` に分けている |

## 移行の後の形

```mermaid
%%{init: {"themeVariables": {"fontSize": "16px"}}}%%
flowchart TD
  U["利用者"] -- "HTTPS（CloudFront の証明書。ACM の us-east-1）" --> CF["CloudFront<br/>代替ドメイン名: app.example.com<br/>WAF の web ACL（国の絞り込み）"]
  CF -- "HTTPS（インターネット。公開のオリジン）<br/>Host は app.example.com のまま、秘密のヘッダーを付ける<br/>接続先は EC2 のパブリック DNS 名" --> SG["稼働サーバーのセキュリティグループ<br/>ステップ 4 の後は CloudFront のプレフィックスリストだけ"]
  SG --> H["稼働サーバーの httpd *:443<br/>オリジンの証明書（Let's Encrypt）"]
```

CloudFront から稼働サーバーまではインターネットを通る（公開のオリジン。VPC オリジンは使わない。[T14](#決めたこと)）ので、HTTPS を続ける。**オリジンの証明書（Let's Encrypt）は残る**。httpd から SSL/TLS の処理をなくしたい場合の構成は、[オプション](#オプション採用しなかった構成既定に入れなかった設定)にある。

## ステップの流れ

```mermaid
%%{init: {"themeVariables": {"fontSize": "16px"}}}%%
flowchart TD
  P["準備<br/>TTL・CAA の確認、httpd の設定（秘密のヘッダーの確認以外）"]
  S1["ステップ 1: ACM の証明書<br/>ACM で作成（採用）か、既存の証明書を登録"]
  C1{"確認 1<br/>証明書が ISSUED で、<br/>us-east-1 にあり、名前が合う"}
  S15["ステップ 1.5: WAF の web ACL（省略できる）<br/>国の絞り込み（us-east-1）"]
  C15{"確認 1.5<br/>web ACL ができ、<br/>ARN が取れた"}
  S2["ステップ 2: CloudFront のルーティング<br/>CloudFront（オリジンは EC2 のパブリック DNS 名）"]
  C2{"確認 2<br/>DNS を変えずに<br/>CloudFront 経由でアプリが動く"}
  S3["ステップ 3: 向き先の変更<br/>app.example.com を CloudFront へ（Route 53）"]
  C3{"確認 3<br/>利用者のドメイン名で<br/>CloudFront を通っている"}
  S4["ステップ 4: オリジンへの接続の制限（後付け）<br/>オリジン用のセキュリティグループ、秘密のヘッダーの確認、全公開の許可の削除"]
  C4{"確認 4<br/>直接の接続が届かず、<br/>CloudFront 経由と証明書の更新は通る"}
  F["片付け<br/>TTL を戻す、証明書の監視、控えのファイル"]
  P --> S1 --> C1 --> S15 --> C15 --> S2 --> C2 --> S3 --> C3 --> S4 --> C4 --> F
  C1 -. "WAF を使わない" .-> S2
```

| ステップ | 行うこと | 使う道具 | 利用者への影響 | 手順 |
|---|---|---|---|---|
| 準備 | DNS の管理先・CAA・TTL の確認、稼働サーバーの httpd の設定 | なし（稼働サーバーの上） | なし | [step0-preparation.md](./step0-preparation.md) |
| 1 | CloudFront の証明書を ACM に用意する。**ACM で作成する（採用）**。既存の証明書を登録する方法は別の節 | **CloudFormation の YAML** `cloudformation/step1-certificate.yml` か **CDK** `<prefix>-step1-certificate`（どちらか一方。`us-east-1`） | なし | [step1-acm-certificate.md](./step1-acm-certificate.md) |
| 1.5 | CloudFront に付ける WAF の web ACL（国の絞り込み）を作る。**CloudFront より前に作る**。WAF を使わないなら省略できる（本番では省略しない）。ステップ 1 とは関係がないので、並べて行ってもよい | **CDK** `<prefix>-step1-5-waf`（`us-east-1`） | なし | [step1-5-waf.md](./step1-5-waf.md) |
| 2 | CloudFront を作り（オリジンは EC2 のパブリック DNS 名）、ステップ 1.5 の WAF を関連付け、DNS を変えずに CloudFront 経由で確かめる（WAF の効き目もここで確かめる）。セキュリティグループは変えない | **CDK** `<prefix>-step2-cloudfront`（`ap-northeast-1`）。`cdk deploy --method=prepare-change-set` か、CDK から YAML のテンプレートを出して AWS CLI で変更セットを作る | なし | [step2-cloudfront.md](./step2-cloudfront.md) |
| 3 | 利用者のドメイン名の向き先を CloudFront へ変える。**Route 53（ステージング）が本線**、外部の DNS サービス（本番）は別の節（手で変える）。**始める前に、httpd の 443 番に `/.well-known/acme-challenge` を入れておく** | **シェルスクリプト** `scripts/step3-dns-switch.sh` | 順次 CloudFront 経由になる | [step3-dns-switch.md](./step3-dns-switch.md) |
| 4 | 稼働サーバーへの接続を CloudFront だけに絞る（後付け）。オリジン用のセキュリティグループを作って足し、httpd で秘密のヘッダーを確かめ、`0.0.0.0/0` の 80・443 番の許可を消す。その後に片付け | **CDK** `<prefix>-step4-origin-sg`（`ap-northeast-1`）、AWS CLI（セキュリティグループの付け替え）、稼働サーバーの httpd | 直接つないでいる相手（IP を指定している相手など）が止まる | [step4-origin-restriction.md](./step4-origin-restriction.md) |

- ステップ 1・1.5・2 は利用者に影響しない。確認で問題が見つかれば、作ったスタックを消すだけで戻せる
- ステップ 3 は、DNS を元のレコードに戻すだけで戻せる（ステップ 4 の後は、先にステップ 4 を戻す）
- ステップ 4 は、消した許可を足し直し、httpd の確認を外せば戻せる
- 定義の中身は [definitions.md](./definitions.md)、CDK のコマンドは [cdk/python/README.md](./cdk/python/README.md)。ステップ 1.5・2・4 の CloudFormation の YAML も同じ内容で残しているが、手順では使わない

## ドキュメント

### 本線（B. CloudFront → EC2）

| ファイル | 内容 |
|---|---|
| このファイル | 結論、ステップの流れ、決めたこと |
| [design-decisions.md](./design-decisions.md) | 設計判断の一覧（決めたこと・理由・とらなかった案・決めた日・資料を 1 つの表に。この README の「決めたこと」との対応も） |
| [step0-preparation.md](./step0-preparation.md) | 準備（ステップ 1 の前）: 事前の確認と、稼働サーバーの httpd の設定 |
| [step1-acm-certificate.md](./step1-acm-certificate.md) | ステップ 1: ACM の証明書の作成（と登録）、確認 1 |
| [step1-5-waf.md](./step1-5-waf.md) | ステップ 1.5: WAF の web ACL（省略できる）、CDK の準備と設定値ファイル、確認 1.5 |
| [step2-cloudfront.md](./step2-cloudfront.md) | ステップ 2: CloudFront（オリジンは EC2 のパブリック DNS 名）、確認 2（WAF の効き目も確かめる） |
| [step3-dns-switch.md](./step3-dns-switch.md) | ステップ 3: 利用者のドメイン名の向き先の変更（`scripts/step3-dns-switch.sh`）、確認 3、元に戻す手順 |
| [step4-origin-restriction.md](./step4-origin-restriction.md) | ステップ 4: オリジンへの接続の制限（後付け）、確認 4、片付け |
| [cloudfront-to-ec2-httpd.md](./cloudfront-to-ec2-httpd.md) | 参考: 稼働サーバーの httpd で行う設定の詳細と、コンテナでの検証の結果 |
| [cloudfront-to-ec2-domains-certificates.md](./cloudfront-to-ec2-domains-certificates.md) | 参考: ドメイン名・DNS のレコード・証明書の役割と、通信の流れ |
| [definitions.md](./definitions.md) | 定義（`cloudformation/` の YAML と `cdk/python/` の CDK）の中身と、ステップごとにどちらを使うか |
| `scripts/step3-dns-switch.sh` | ステップ 3 のシェルスクリプト（Route 53 の A レコードの置き換えと戻し） |
| [cdk/python/README.md](./cdk/python/README.md) | CDK（Python）版の準備・合成・デプロイ・撤去のコマンド |

### オプション（採用しなかった構成・既定に入れなかった設定）

| ファイル | 内容 |
|---|---|
| [options/vpc-origin.md](./options/vpc-origin.md) | CloudFront から稼働サーバーへ、インターネットを通さずに接続する VPC オリジンの条件と、移すときにすること（今はとらない） |
| [options/waf-managed-rules.md](./options/waf-managed-rules.md) | ステップ 2 の WAF に、AWS のマネージドルールとログを足す方法（count で試してから block にする流れ）と、既定から外す前の定義の設定値 |
| [options/comparison.md](./options/comparison.md) | 3 つの構成（A. ALB → EC2、B. CloudFront → EC2、C. CloudFront → ALB → EC2）の比較、ALB を通さないことのデメリット、WAF を置ける場所 |
| [options/alb-to-ec2.md](./options/alb-to-ec2.md) | A. ALB → EC2 への移行の手順 |
| [options/cloudfront-alb-to-ec2.md](./options/cloudfront-alb-to-ec2.md) | C. CloudFront → ALB → EC2 への移行の手順 |
| `cloudformation/options/` | A と C の CloudFormation の YAML |
| `cdk/python/tls_termination_cdk/stacks/options/` | A と C の CDK（設定値の `option_stacks` で指定したときだけ合成する） |

## 結論

- **B. CloudFront → EC2 で進める**（2026-11-11）。目的は **WAF による防御**で、WAF は CloudFront に付ける（EC2 には直接付けられない）
- **オリジンの証明書（Let's Encrypt）は残る**。CloudFront から稼働サーバーまではインターネットを通るので、HTTPS を続ける
- **利用者のドメイン名は変えない**。CloudFront の接続先には、別の名前（オリジンの名前）を使う
- 国の絞り込みは **WAF** で行い、`/.well-known/acme-challenge/` だけはどの国からも通す（オリジンの証明書を HTTP-01 で更新し続けるため）。CloudFront の地理的制限は使わない。既定の WAF は国の絞り込みだけで、マネージドルールとログはオプション
- httpd から証明書と SSL/TLS の処理をなくしたい場合は、ALB を通すオプションの構成（A・C）になる。比較は [options/comparison.md](./options/comparison.md)

## 決めたこと

理由・とらなかった案まで含めた一覧は [design-decisions.md](./design-decisions.md)。

| # | 論点 | 決めたこと |
|---|---|---|
| T1 | 何のために移すのか | **WAF による防御**（2026-11-11） |
| T2 | 3 つの構成のどれにするか | **B. CloudFront → EC2**（2026-11-11）。対象が多数の台なら、[ALB を共有する案](../ec2/notes/instance-provisioning/cloudfront-alb-front-options.md#今の運用物件ごとの単体のサーバーに当てはめた選択肢)も含めて考え直す |
| T3 | `old_app_a` の扱い | **考えなくてよい**（2026-11-17）。前の版で「443 番へ移す」としていたのは、別のアプリの事例が混じったもの。この稼働サーバーの 80 番は、`/.well-known/acme-challenge` 以外をすべて HTTPS へリダイレクトしている |
| T4 | 国で絞る場所 | **WAF**（確認のパスだけを例外にする。2026-11-11）。この移行の対象の台には port-guard を入れていない（port-guard-rollout の対象は別の台。2026-11-11）ので、port-guard を外す作業はない |
| T5 | オリジンの証明書の更新の経路 | **CloudFront と WAF を経た HTTP-01**（T4 に伴う。[cloudfront-to-ec2-httpd.md](./cloudfront-to-ec2-httpd.md#証明書の更新)） |
| T6 | CloudFront の証明書の用意の仕方 | **ACM で作成する**（2026-11-12）。既存の証明書の登録は、ACM が自動で更新しないので別の節に分けた |
| T7 | 利用者のドメイン名の DNS | **ステージングは Route 53、本番は外部の DNS サービス**（2026-11-11）。手順は Route 53 を本線にし、外部の DNS サービスは各ステップの別の節に書いた（2026-11-12） |
| T8 | ステップ 3 を CloudFormation とシェルスクリプトのどちらで行うか | **シェルスクリプト**（`scripts/step3-dns-switch.sh`。2026-11-12）。利用者のドメイン名のレコードは今もあり、CloudFormation で作るには先に消すかスタックへの取り込みが要る。シェルスクリプトなら、今のレコードを読んで 1 つの変更バッチで置き換え、戻すのも逆の変更バッチで済む（[比べた表](./step3-dns-switch.md#シェルスクリプトにした理由)） |
| T9 | ステップ 1・2 の道具 | **ステップ 1 は CloudFormation の YAML（量がないため）を基本に、CDK でも行えるよう手順書に両方を書く。ステップ 2 は CDK**（2026-11-12。ステップ 1 の併記は 2026-11-13）。ステップ 2 は WAF のルールと CloudFront の設定の量が多い。CDK は、`cdk deploy --method=prepare-change-set` で変更セットを作る方法と、CDK から CloudFormation のテンプレート（YAML）を出して AWS CLI で変更セットを作る方法の両方を書いた（実行はどちらもコンソール。T11）（[cdk/python/README.md のデプロイ](./cdk/python/README.md#デプロイ)。2026-11-13）。どちらも `cdk bootstrap` はしない。両方の書き方の定義は残している |
| T10 | 既定の WAF に何を入れるか | **国の絞り込みだけ**（`AllowAcmeChallenge` と `BlockOutsideAllowedCountries`。2026-11-13）。AWS のマネージドルールとログは既定から外し、入れ方と外す前の設定値を [options/waf-managed-rules.md](./options/waf-managed-rules.md) に残した。定義が短くなり（WAF の CDK の定義が 236 行 → 155 行。今の `step1_5_waf.py`）、料金は月 $10 → $7 と要求の料金。許可する国と例外の IP から来る攻撃は WAF では止めない |
| T11 | CloudFormation の変更をどこで反映するか | **端末（AWS CLI・`cdk`）では変更セットを作るところまで。変更セットの中身の確認と実行、スタックの削除は AWS のコンソールで行う**（2026-11-16）。手順は [definitions.md の「変更セットをコンソールで実行する」](./definitions.md#変更セットをコンソールで実行する)。ステップ 3 の DNS の切り替え（シェルスクリプト）と、ステップ 4 のセキュリティグループの付け替えと許可の削除（AWS CLI）は CloudFormation ではないので、この決まりの外 |
| T12 | WAF をどのステップで作るか | **ステップ 1.5**（ステップ 1 と 2 の間。2026-11-16）。WAF は CloudFront より前に要る（CloudFront の作成のときに ARN を渡す）が、ステップ 1 の証明書とは関係がない。WAF を使わないなら省略できるので、ステップ 2 から分けた。3 つのステップ（証明書 → CloudFront → DNS）の形は保つ。WAF の効き目は CloudFront を通さないと確かめられないので、確認はステップ 2 の確認 2 で行う。スタック名は `<prefix>-step1-5-waf`（スタック名に `.` は使えない） |
| T13 | オリジンの名前 | **稼働サーバーの EC2 のパブリック DNS 名**（2026-11-17）。自分のドメインに `origin.app.example.com` を作らずに済み、本番の外部の DNS サービスへ頼む作業が 1 回減る。オリジンの証明書は今のまま通る（CloudFront は Host ヘッダーに `app.example.com` を渡し、証明書はその名前で照合される）。条件は Elastic IP が付いていて、VPC の DNS ホスト名の設定が有効なこと。Elastic IP を付け替えたら、CloudFront の更新が要る。自分のドメインの名前を使う形も、定義には残している |
| T14 | CloudFront から稼働サーバーへの接続の方式 | **公開のオリジン**（インターネット経由の HTTPS。2026-11-17）。VPC オリジン（プライベートな接続）は、稼働サーバーをプライベートサブネットに置く必要があり、Elastic IP を指定している相手が止まり、外への通信に NAT ゲートウェイが要るので、今はとらない。[options/vpc-origin.md](./options/vpc-origin.md) に書き出した |
| T15 | 稼働サーバーへの接続を CloudFront だけに絞る時期 | **ルーティングができた後のステップ 4 で、後から付ける**（2026-11-17）。今の稼働サーバーは 80・443 番を全公開しているので、絞らなくても CloudFront から届く。オリジン用のセキュリティグループはステップ 2 のスタックから分け、ステップ 4 の別のスタック（`<prefix>-step4-origin-sg`）にした。秘密のヘッダーの確認と全公開の許可の削除（前はステップ 3 の片付け）も、ステップ 4 に移した |

## どの手順でも共通して確かめること

| 項目 | 内容 |
|---|---|
| IP で直接つないでいる相手 | Elastic IP を指定して API を呼んでいる相手は、切り替えの後も CloudFront を通らず稼働サーバーへ向かい、片付けの後はセキュリティグループで止まる。[API のアクセス元の洗い出し](../ec2-port-guard-rollout/api-access-sources/design.md)で探す |
| 外部に Elastic IP を伝えている先 | 稼働サーバーから外へ出る通信の送り元は変わらない。Elastic IP を外すときだけ影響する |
| 古い TLS しか話せない相手 | CloudFront のセキュリティポリシー（TLSv1.2_2021）で受ける TLS のバージョンが変わる |
| HTTP から HTTPS へのリダイレクト | `POST` で HTTP を呼ぶ API のクライアントは、リダイレクトで動かなくなることがある |
| Rails の `force_ssl`、Secure の Cookie、URL の生成 | Rails が元の接続を HTTPS と認識できることが前提（コンテナで確かめた。[検証の結果](./cloudfront-to-ec2-httpd.md#検証の結果)） |
| AL2023 での作り直し | この移行を[作り直し](../ec2/initial-image-build/existing-system-rebuild-on-al2023.md)と同時に行うなら、新しい土台の Apache の設定に最初から入れる |

## 参考

AWS のドキュメントと照らし合わせた（2026-11-09）。ステップごとの参考は各ドキュメントに書いた。

- [Resources that you can protect with AWS WAF](https://docs.aws.amazon.com/waf/latest/developerguide/how-aws-waf-works-resources.html)
- [Requirements for using SSL/TLS certificates with CloudFront](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html)
- [Require HTTPS between CloudFront and your custom origin](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-https-cloudfront-to-custom-origin.html)
