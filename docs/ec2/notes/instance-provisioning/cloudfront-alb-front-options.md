# 補足: 配布先のインスタンスの前段の構成（CloudFront と ALB）

> 位置付け: 検討の材料。採用済みの設計ではない。配った AMI から起動したインスタンス（本番など）の前に、CloudFront や ALB を置く構成の比較と、料金の考え方をまとめる。決まったことは [設計: フェーズ 2](../../instance-provisioning/design.md) の論点 P2（置き換え後の同一性の保ち方）・P3（サーバーのスタックに含めるもの）・P7（置き換え時の停止時間）に反映する。
>
> 関連: [Amazon Linux 2023 の運用のチップス](../ec2-operations/amazon-linux-2023-operations-tips.md#補足-無停止の更新は-os-ではなく台数と入れ替えで作る)（無停止の更新は台数と入れ替えで作る）、[ブルーグリーンによる無停止の切り替え（候補）](../../instance-provisioning/blue-green-switching-candidate.md)
>
> 調査日: 2026-10-27（料金や機能は変わることがあるため、使う前に AWS の料金のページと文書で確認する。「未確認」と書いた点は、確かめてから使う）

## 結論

- 「CloudFront → EC2」も「ALB → EC2」も、どちらもよくある構成である。ただし目的が違う。規模が大きめのサイトでは、両方を重ねた「CloudFront → ALB → EC2」も一般的である
- **ALB** は負荷分散とヘルスチェックの役で、複数台・ローリングアップデートの土台になる。**置いておくだけで時間課金がかかる**
- **CloudFront** はキャッシュと配信、TLS の終端、WAF などの入口の役で、**負荷分散はしない**。従量課金なら**置いておくだけの費用はかからない**（月額固定のプランもある）
- 今の運用（物件ごとの単体のサーバー）に当てはめると、「ALB を 1 つ共有して、ホスト名でサーバーごとに振り分ける」形も選択肢になる

## 3 つの構成

| 構成 | よく使われる場面 | 主な役割 |
|---|---|---|
| **ALB → EC2** | Web アプリの標準的な形。複数台の負荷分散、Auto Scaling グループ | 負荷分散、ヘルスチェック（異常な台を外す）、ACM の証明書での TLS の終端、ローリングアップデートの土台 |
| **CloudFront → EC2（直接）** | 単体のサーバーのサイト、静的なコンテンツが多いサイト、ALB の費用を避けたい小さめの構成 | キャッシュと配信の高速化、ACM の証明書での TLS の終端、WAF や DDoS 対策の入口 |
| CloudFront → ALB → EC2 | 規模が大きめのサイト | 上の 2 つの両方 |

## CloudFront → EC2（直接）の注意点

| 項目 | 内容 |
|---|---|
| 負荷分散はしない | オリジン（EC2）が 1 台なら、その台が止まればサイトも止まる。オリジングループで予備の台への切り替えはできるが、負荷分散ではない。ローリングアップデートの代わりにはならず、無停止の入れ替えは別に考える |
| EC2 への直接のアクセスを塞ぐ | セキュリティグループで CloudFront からの通信だけを許可する（AWS が提供する CloudFront のプレフィックスリストを使う）か、CloudFront の VPC オリジン（プライベートサブネットの EC2 や ALB をオリジンにできる機能。2024 年に追加）を使う |
| CloudFront から EC2 までの暗号化 | HTTPS にするなら、EC2 側にもオリジンのドメイン名で有効な証明書が要る（Let's Encrypt が残る）。VPC オリジンなら AWS の内部の経路になる |
| 動的なアプリ（Rails など） | キャッシュを無効にする設定（ログイン後のページ、フォームの送信など）が要る。オリジンの応答待ちの上限（既定 30 秒）にも注意する |

## ALB → EC2 の注意点

| 項目 | 内容 |
|---|---|
| 時間課金 | ALB は、つないでいる EC2 が 1 台でも時間課金がかかる（LCU の課金も加わる）。単体のサーバーが多いと、1 台ごとに ALB を置く費用が積み上がる |
| Elastic IP | DNS は ALB を指す別名レコードになり、1 台ごとの Elastic IP は不要になる |
| 証明書 | ACM の証明書を ALB で使う。EC2 の Let's Encrypt は不要になる |
| 複数台にする場合 | アプリを複数台で動かせる必要がある（セッション、アップロードしたファイル、定期実行の重複など） |

## 料金の考え方

### CloudFront

**従量課金（pay-as-you-go）**: 時間課金はなく、使った分だけかかる。アクセスがなければ、ほぼ費用はかからない。

| 課金されるもの | 内容 |
|---|---|
| インターネットへのデータ転送量 | 利用者に返したデータの量（地域ごとの単価） |
| リクエストの数 | HTTP / HTTPS のリクエストの数 |
| 使った追加の機能 | CloudFront Functions、Lambda@Edge、リアルタイムのログ、一定数を超えるキャッシュの削除（無効化）、独自ドメインの専用 IP の証明書（SNI なら追加費用なし）など |

- AWS のオリジン（EC2 や ALB）から CloudFront への転送は課金されない（**未確認**。調査では確かめていない）
- 無料枠（毎月一定量の転送とリクエスト）の今の量は**未確認**

**月額固定の料金プラン（2025 年に追加）**:

| プラン | 月額 |
|---|---|
| Free | $0 |
| Pro | $15 |
| Business | $200 |
| Premium | $1,000 |

- CDN の配信に、WAF、DDoS 対策、ボット対策、Route 53 の DNS、CloudWatch Logs への取り込みなどがまとめて含まれる
- アクセスの急増や攻撃があっても、超過分の料金はかからない。年間の契約は不要
- プランごとの転送量などの上限は**未確認**

### ALB と CloudFront の比較

| | CloudFront | ALB |
|---|---|---|
| 置いておくだけの費用 | **なし**（従量課金の場合） | **あり**（時間課金） |
| 使った分の費用 | 転送量とリクエストの数 | LCU（接続数、リクエスト数、処理したデータ量などの最大値で決まる単位） |

アクセスの少ないサーバーがたくさんある構成では、CloudFront の方が費用の面で有利になりやすい。

## 今の運用（物件ごとの単体のサーバー）に当てはめた選択肢

今の運用は、1 台ごとにサブドメイン・Elastic IP・Let's Encrypt の証明書を持つ単体のサーバーが多数ある形である（[今の手作業の手順](../../instance-provisioning/manual-procedure-analysis.md)）。

| 選択肢 | 内容 | 利点 | 注意 |
|---|---|---|---|
| A. 今のまま（EC2 直接） | 1 台ごとに Elastic IP と Let's Encrypt | 追加の費用なし | 証明書の管理と、入れ替え時の Elastic IP・DNS・証明書の引き継ぎが 1 台ごとに要る |
| B. ALB を 1 つ共有 | 1 つの ALB で、ホスト名（サブドメイン）ごとに各サーバーへ振り分ける。ACM のワイルドカード証明書を使う | Let's Encrypt と 1 台ごとの Elastic IP が不要。ALB の費用を全台で分け合える。入れ替えは、新しい台を登録してから古い台を外す（DNS の切り替えより扱いやすい） | どのサーバーも 1 台のまま。ALB の 1 つのリスナーに付けられるルールの数などの上限に注意（数は**未確認**） |
| C. サーバーごとに CloudFront | サーバーごとに CloudFront を置き、EC2 をオリジンにする | 置いておくだけの費用がない。WAF などの入口になる | オリジンまでの暗号化（Let's Encrypt が残るか、VPC オリジン）、EC2 への直接のアクセスを塞ぐ設定、入れ替え時のオリジンの付け替え |
| D. ALB ＋複数台（Auto Scaling グループ） | サーバーを複数台にしてローリングアップデート | 無停止の入れ替え | アプリを複数台で動かせる必要があり、配布先の構成そのものの変更になる |

## 決めること

| # | 論点 | 関わる論点（フェーズ 2） |
|---|---|---|
| F1 | 前段を置くか（A〜D のどれか） | P2・P3・P7 |
| F2 | 証明書を Let's Encrypt から ACM に移すか | P3、[Let's Encrypt の扱い](./letsencrypt-certificate-timing.md) |
| F3 | WAF などの入口の対策が要るか | — |
| F4 | 費用の見積もり（サーバーの台数とアクセスの量から） | — |

## 参考

- [Amazon CloudFront pricing](https://aws.amazon.com/en/cloudfront/pricing)
- [CloudFront flat-rate pricing plans - Amazon CloudFront](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html)
- [Amazon CloudFront flat-rate pricing plans: new features and expanded capabilities](https://aws.amazon.com/blogs/networking-and-content-delivery/amazon-cloudfront-flat-rate-pricing-plans-new-features-and-expanded-capabilities)
