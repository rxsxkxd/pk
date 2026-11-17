# 設計判断の一覧

> 位置付け: B. CloudFront → EC2 への移行で、これまでに決めた設計判断を 1 つの表にまとめたもの。論点ごとに、決めたこと、理由、とらなかった案、決めた日、詳しい資料を並べる。README の「[決めたこと](./README.md#決めたこと)」（T1〜T15）と、各資料に散らばっていた判断を集めた。手順の全体は [README](./README.md#ステップの流れ)。
>
> 作成日: 2026-11-17（取り違えやすい語に正確な名前を付けて書き直した: 2026-11-17）

## 用語

[README の用語](./README.md#用語)に加えて、この資料では次の名前で書き分ける。似た語を単独では使わない。

| 用語 | 指すもの |
|---|---|
| CloudFront の証明書 | 利用者と CloudFront の間で使う証明書。ACM の `us-east-1` に作る（ステップ 1） |
| オリジンの証明書 | CloudFront と稼働サーバーの間で使う証明書。稼働サーバーの httpd にある今の Let's Encrypt の証明書 |
| オリジンの証明書の更新 | certbot が Let's Encrypt から、オリジンの証明書を取り直すこと（90 日ごと） |
| CloudFront の証明書の自動更新 | ACM が、CloudFront の証明書を自動で取り直すこと |
| HTTP-01 の検証の要求 | オリジンの証明書の更新のときに、Let's Encrypt が `http://app.example.com/.well-known/acme-challenge/...` へ送る要求 |
| HTTP-01 の検証のパス | `/.well-known/acme-challenge/`。HTTP-01 の検証の要求が来るパス |
| ACM の検証用の CNAME | ACM が CloudFront の証明書を発行・自動更新するために DNS に置く CNAME レコード |
| 確認 *n*（ステップの確認） | 各ステップの最後に行う、次のステップへ進んでよいかを確かめる作業（確認 1・1.5・2・3・4） |
| 秘密のヘッダーの照合 | 稼働サーバーの httpd が、CloudFront の付ける秘密のヘッダー（`X-Origin-Verify`）の値を確かめ、合わない要求を 403 にすること |
| オリジン用のセキュリティグループ | CloudFront のプレフィックスリストから 443 番だけを許可する、新しく作るセキュリティグループ（ステップ 4 のスタック `<prefix>-step4-origin-sg`） |
| 稼働サーバーの今のセキュリティグループ | 稼働サーバーに今付いているセキュリティグループ。80・443 番を全公開している |
| 稼働サーバーへの直接の接続 | CloudFront を通らずに、稼働サーバーの Elastic IP へ来る接続 |
| Elastic IP を指定している相手 | 名前ではなく稼働サーバーの Elastic IP を指定して接続している相手（API の呼び出し元など） |
| 切り替え | ステップ 3 で、利用者のドメイン名の DNS の向き先を、稼働サーバーの Elastic IP から CloudFront へ変えること |
| 切り替えの戻し | 切り替えを元に戻し、利用者のドメイン名の DNS の向き先を稼働サーバーの Elastic IP へ戻すこと |
| Host ヘッダー | 利用者の要求の `Host`（`app.example.com`）。`AllViewer` で稼働サーバーまでそのまま渡る |
| WAF のログ | WAF の web ACL の要求の記録（CloudWatch Logs）。既定では残さない |
| httpd のアクセスログ | 稼働サーバーの httpd の `access.log` |
| 定義 | CloudFormation の YAML（`cloudformation/`）と CDK（`cdk/python/`）の両方を指す。片方だけを指すときは「YAML」「CDK」と書く |

「README の T*n*」は、README の「決めたこと」の表の番号を指す。日付が「—」のものは、決めた日の記録が残っていない。

## 一覧

| 分類 | 判断 |
|---|---|
| [構成](#構成) | D1〜D6 |
| [防御（WAF・稼働サーバーへの直接の接続）](#防御waf稼働サーバーへの直接の接続) | D7〜D11 |
| [CloudFront の設定](#cloudfront-の設定) | D12〜D14 |
| [CloudFront の証明書](#cloudfront-の証明書) | D15〜D16 |
| [DNS と切り替え](#dns-と切り替え) | D17〜D19 |
| [道具と反映の仕方](#道具と反映の仕方) | D20〜D23 |
| [稼働サーバーの httpd](#稼働サーバーの-httpd) | D24〜D27 |

## 構成

| # | 論点 | 決めたこと | 理由 | とらなかった案 | 決めた日 | 詳しく |
|---|---|---|---|---|---|---|
| D1 | 構成 | **B. CloudFront → EC2** | WAF を CloudFront に付けられ、ALB の時間課金がかからない | A. ALB → EC2（ALB に ACM の証明書を付け、稼働サーバーのオリジンの証明書をなくせるが、ALB の料金がかかる。比べたときの既定の案だった）、C. CloudFront → ALB → EC2（CloudFront と ALB の両方の料金と手間がかかる） | 2026-11-11 | README の T2、[options/comparison.md](./options/comparison.md) |
| D2 | 利用者のドメイン名 | **変えない**（`app.example.com` のまま。CloudFront の代替ドメイン名にする） | 利用者のドメイン名の DNS の向き先を変えるだけで、切り替えと切り替えの戻しができる（理由の記録はなく、手順の前提から書いた） | 利用者のドメイン名を新しい名前に変える | — | [README の結論](./README.md#結論) |
| D3 | CloudFront から稼働サーバーへの接続の方式 | **公開のオリジン**（インターネット経由の HTTPS） | 稼働サーバーのネットワークを変えずに済む | VPC オリジン（稼働サーバーをプライベートサブネットへ移す必要があり、Elastic IP を指定している相手が止まり、稼働サーバーから外への通信に NAT ゲートウェイが要る） | 2026-11-17 | README の T14、[options/vpc-origin.md](./options/vpc-origin.md) |
| D4 | オリジンの名前 | **稼働サーバーの EC2 のパブリック DNS 名** | 自分のドメインにオリジンの名前の A レコードを作らずに済み、本番の外部の DNS サービスへ頼む作業が 1 回減る。オリジンの証明書は Host ヘッダーの名前（`app.example.com`）で照合されるので、今のまま通る | 自分のドメインのオリジンの名前（`origin.app.example.com`。定義には残している） | 2026-11-17 | README の T13、[ステップ 2 の 2-1](./step2-cloudfront.md#2-1-オリジンの名前) |
| D5 | オリジンの証明書と、CloudFront から稼働サーバーへのプロトコル | **オリジンの証明書（今の Let's Encrypt の証明書）を残し、HTTPS を続ける** | CloudFront から稼働サーバーまではインターネットを通る | HTTP にする（インターネットを平文で通る）、オリジンの証明書を ACM の ACME 証明書かエクスポートできる証明書にする（この用途で試しておらず、エクスポートできる証明書は有料） | 2026-11-11 | [README の結論](./README.md#結論)、[cloudfront-to-ec2-httpd.md の「証明書の更新」（オリジンの証明書の更新）](./cloudfront-to-ec2-httpd.md#証明書の更新) |
| D6 | オリジンの証明書の更新の経路 | **CloudFront と WAF を経た HTTP-01** | 今の certbot の設定のまま続けられる。Let's Encrypt は、HTTP-01 の検証の要求で 80 番から 443 番へのリダイレクトをたどる | DNS-01（DNS の API の権限の持たせ方を決める必要がある） | 2026-11-11 | README の T5、[cloudfront-to-ec2-domains-certificates.md](./cloudfront-to-ec2-domains-certificates.md) の C1 |

## 防御（WAF・稼働サーバーへの直接の接続）

| # | 論点 | 決めたこと | 理由 | とらなかった案 | 決めた日 | 詳しく |
|---|---|---|---|---|---|---|
| D7 | 国で絞る場所 | **WAF**（HTTP-01 の検証のパスだけを、国で絞らない例外にする） | WAF ならパスの例外を作れる | CloudFront の地理的制限（地理的制限で止めた要求は WAF に届かず、HTTP-01 の検証の要求も止まる）。port-guard はこの稼働サーバーに入っていないので、外す作業はない | 2026-11-11 | README の T4、[definitions.md の WAF](./definitions.md#ステップ-15-の-waf国の絞り込み) |
| D8 | 既定の WAF に何を入れるか | **国の絞り込みだけ**（WAF のルール 2 つ） | WAF の定義が短くなり、WAF の料金は月 $10 → $7 と要求の料金になる | AWS のマネージドルールと WAF のログ（入れ方と外す前の設定値を残した）。入れないので、許可する国と例外の IP から来る攻撃は WAF では止めない | 2026-11-13 | README の T10、[options/waf-managed-rules.md](./options/waf-managed-rules.md) |
| D9 | WAF をどのステップで作るか | **ステップ 1.5**（ステップ 1 と 2 の間。WAF を使わないなら省略できる） | WAF は CloudFront より前に要るが、ステップ 1 の CloudFront の証明書とは関係がない。WAF の効き目は確認 2（ステップ 2 の確認）で確かめる | ステップ 2 の中に置く、独立のステップにして番号を振り直す | 2026-11-16 | README の T12、[step1-5-waf.md](./step1-5-waf.md) |
| D10 | 稼働サーバーへの直接の接続を止める方法 | **オリジン用のセキュリティグループと、秘密のヘッダーの照合の両方** | CloudFront のプレフィックスリストは CloudFront 全体の範囲で、他人のディストリビューションからも届くので、秘密のヘッダーの照合も要る | オリジン用のセキュリティグループだけ | — | [step4-origin-restriction.md](./step4-origin-restriction.md)、[cloudfront-to-ec2-httpd.md の 3（秘密のヘッダーの照合）](./cloudfront-to-ec2-httpd.md#3-秘密のヘッダーを確認する) |
| D11 | 稼働サーバーへの直接の接続を止める時期 | **ルーティングができた後のステップ 4 で、後から付ける**。オリジン用のセキュリティグループは、ステップ 4 の別の CloudFormation のスタック（`<prefix>-step4-origin-sg`）にする | 稼働サーバーの今のセキュリティグループは 80・443 番を全公開しているので、絞らなくても CloudFront から届く。ルーティングを先に作れる | ステップ 2 で CloudFront と一緒にオリジン用のセキュリティグループを作って付ける（前の版） | 2026-11-17 | README の T15、[step4-origin-restriction.md](./step4-origin-restriction.md) |

## CloudFront の設定

| # | 論点 | 決めたこと | 理由 | とらなかった案 | 決めた日 | 詳しく |
|---|---|---|---|---|---|---|
| D12 | CloudFront のキャッシュ | **キャッシュしない**（`CachingDisabled`） | 利用者ごとに違う応答を CloudFront に保存しない | 静的なファイルのキャッシュ（使うと決まってから足す） | — | [ステップ 2 の 2-2](./step2-cloudfront.md#2-2-cloudfront-を作る) |
| D13 | CloudFront が稼働サーバーへ渡すもの | **`AllViewer`**（Host ヘッダー・Cookie・クエリ文字列・`Authorization` をすべて渡す） | Host ヘッダーが利用者のドメイン名のまま届くので、Rails のリダイレクト先が正しく、オリジンの証明書も Host ヘッダーの名前で受け入れられる | Host ヘッダーを渡さない（オリジンの証明書がオリジンの名前に合わず 502 になり、Rails のリダイレクト先もオリジンの名前になる） | — | [cloudfront-to-ec2-domains-certificates.md](./cloudfront-to-ec2-domains-certificates.md#前提が崩れたときに起きること) |
| D14 | CloudFront の IPv6 | **無効** | ステップ 3 で利用者のドメイン名に作る DNS のレコードを、A だけにできる | 有効にする（利用者のドメイン名に AAAA のレコードも要る） | — | [ステップ 2 の 2-2](./step2-cloudfront.md#2-2-cloudfront-を作る) |

## CloudFront の証明書

| # | 論点 | 決めたこと | 理由 | とらなかった案 | 決めた日 | 詳しく |
|---|---|---|---|---|---|---|
| D15 | CloudFront の証明書の用意の仕方 | **ACM で作成する**（DNS 検証） | CloudFront の証明書の自動更新が効く（ACM の検証用の CNAME を残し、CloudFront の証明書が CloudFront に付いている間） | 既存の証明書を ACM に登録する（CloudFront の証明書の自動更新が効かない。別の節に残した） | 2026-11-12 | README の T6、[step1-acm-certificate.md](./step1-acm-certificate.md) |
| D16 | CloudFront の証明書に使う ACM の種類 | **ACM のコンソールの「証明書」**（通常の公開証明書） | CloudFront に付けられるのはこちら | ACM のコンソールの「ACME 証明書」（CloudFront に付けられない） | 2026-11-12 | [ステップ 1 の「証明書の種類」（CloudFront の証明書）](./step1-acm-certificate.md#証明書の種類) |

## DNS と切り替え

| # | 論点 | 決めたこと | 理由 | とらなかった案 | 決めた日 | 詳しく |
|---|---|---|---|---|---|---|
| D17 | 利用者のドメイン名の DNS の扱い | **手順は Route 53（ステージング）を本線にし、外部の DNS サービス（本番）は各ステップの別の節に書く** | 利用者のドメイン名の DNS の管理先が、ステージングは Route 53、本番は外部の DNS サービス | — | 2026-11-11（DNS の管理先が分かった日）、2026-11-12（手順の書き方） | README の T7 |
| D18 | 切り替えの前の準備 | **利用者のドメイン名の DNS の TTL を短くして、元の TTL が過ぎてから切り替える** | 切り替えと切り替えの戻しが早く行き渡る | — | — | [準備の 2](./step0-preparation.md#2-ttl-を短くする) |
| D19 | 切り替え（ステップ 3）の道具 | **シェルスクリプト**（`scripts/step3-dns-switch.sh`） | 利用者のドメイン名の今の A レコードを読んで 1 つの変更バッチで置き換え、切り替えの戻しも逆の変更バッチで済む | CloudFormation（利用者のドメイン名の今の A レコードを先に消すか、スタックへの取り込みが要り、切り替えの戻しも 2 段階） | 2026-11-12 | README の T8、[比べた表](./step3-dns-switch.md#シェルスクリプトにした理由) |

## 道具と反映の仕方

| # | 論点 | 決めたこと | 理由 | とらなかった案 | 決めた日 | 詳しく |
|---|---|---|---|---|---|---|
| D20 | ステップごとの定義の道具 | **ステップ 1 は YAML を基本に CDK も併記。ステップ 1.5・2・4 は CDK**。YAML と CDK の両方の定義を残す | ステップ 1 はリソースが 1 つで量がない。WAF と CloudFront は設定の量が多く、CDK の設定値ファイル 1 つにまとめられる | — | 2026-11-12（ステップ 1 の併記は 2026-11-13） | README の T9、[definitions.md](./definitions.md) |
| D21 | YAML と CDK の使い分け | **1 つの環境では、YAML か CDK のどちらか一方を使い続ける** | YAML と CDK では論理 ID が違うので、混ぜるとリソースが作り直される | — | 2026-11-13 | [ステップ 1 の 1-A-0](./step1-acm-certificate.md#1-a-0-cloudformation-と-cdk-のどちらで行うか) |
| D22 | CDK の使い方 | **`cdk bootstrap` はしない**。変更セットは、`cdk deploy --method=prepare-change-set` か、CDK から出した CloudFormation のテンプレート（YAML）を AWS CLI に渡して作る | アセットがなく、CloudFormation のテンプレートが 51,200 バイト未満なので、ブートストラップしなくてよい（AWS のドキュメント） | `cdk deploy` で端末から直接反映する（D23 で、端末からの反映をやめた） | 2026-11-13 | [cdk/python/README.md の方針](./cdk/python/README.md#方針) |
| D23 | CloudFormation の変更の反映 | **端末では変更セットを作るところまで。変更セットの中身を見ること、変更セットの実行、スタックの削除は AWS のコンソールで行う** | — | 端末から変更セットを実行する | 2026-11-16 | README の T11、[変更セットをコンソールで実行する](./definitions.md#変更セットをコンソールで実行する) |

## 稼働サーバーの httpd

| # | 論点 | 決めたこと | 理由 | とらなかった案 | 決めた日 | 詳しく |
|---|---|---|---|---|---|---|
| D24 | 利用者の IP の復元（`mod_remoteip`）の時期 | **切り替えの前（準備）に入れる**。`RequestHeader unset X-Forwarded-For` も一緒に入れる | CloudFront を通る最初の要求から、httpd のアクセスログとアプリに利用者の IP が出て、確認 2（ステップ 2 の確認）で効いていることを確かめられる。今の構成では、利用者の IP が残るのは httpd のアクセスログだけ（WAF のログは残さない） | 入れない（httpd のアクセスログとアプリの送り元がすべて CloudFront の IP になる）、切り替えの後に入れる | 2026-11-17 | [準備の 3](./step0-preparation.md#3-稼働サーバーの-httpd-の設定)、[cloudfront-to-ec2-httpd.md の 4](./cloudfront-to-ec2-httpd.md#4-利用者の-ip-を復元する) |
| D25 | 443 番の HTTP-01 の検証のパスの時期 | **遅くともステップ 3 の前**（準備で入れてよい） | 切り替えの後の最初のオリジンの証明書の更新で、HTTP-01 の検証の要求が CloudFront を通って稼働サーバーの 443 番に届く | — | 2026-11-17 | [ステップ 3 の始める前に](./step3-dns-switch.md#始める前にステップ-3-へ進む前の条件) |
| D26 | 秘密のヘッダーの照合の時期 | **ステップ 4**（切り替えが行き渡ってから） | 先に入れると、まだ稼働サーバーへ直接来ている利用者が 403 になる | 準備で入れる | 2026-11-17（ステップ 4 に移した日） | [ステップ 4 の 4-3](./step4-origin-restriction.md#4-3-httpd-で秘密のヘッダーを確かめる) |
| D27 | httpd の `KeepAliveTimeout` | **10 秒**（CloudFront の keep-alive timeout の 5 秒より長く） | httpd が先に CloudFront との接続を閉じると、CloudFront が閉じた接続を使ってエラーになることがある | 今の値のまま | — | [cloudfront-to-ec2-httpd.md の 5](./cloudfront-to-ec2-httpd.md#5-keepalivetimeout) |

## README の「決めたこと」との対応

README の T1（移す目的）と T3（`old_app_a`）は、この資料には載せていない。

| README | この資料 |
|---|---|
| T2 | D1 |
| T4 | D7 |
| T5 | D6 |
| T6 | D15 |
| T7 | D17 |
| T8 | D19 |
| T9 | D20 |
| T10 | D8 |
| T11 | D23 |
| T12 | D9 |
| T13 | D4 |
| T14 | D3 |
| T15 | D11 |
