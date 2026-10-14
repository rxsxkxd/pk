# システム構成概要

稼働するシステムの構成要素だけを、1行ずつまとめる（デプロイの仕組みなどは書かない）。設定で切り替えられる項目は、既定の構成だけを書く（2026-10-14 時点の `master`）。詳しくは [DESIGN.md](DESIGN.md)、[web/DESIGN.md](web/DESIGN.md)、[web/DEPLOY.md](web/DEPLOY.md)。

| 項目 | 現状 |
|---|---|
| 実装言語 | API は Go 1.27 で、Lambda（`provided.al2023`、arm64）で動かす。画面は Vue 3.5 + TypeScript の SPA。 |
| 対応 OS | iOS 13 以上 / Android 9 以上（**実機での確認はまだ**）。 |
| 画像サイズ上限 | 4MiB（4,194,304 バイト）。 |
| 画像圧縮 | 上限を超えた写真だけ、SPA が Compressor.js で JPEG に縮めてから送る（上限以下はそのまま送り、API 側は加工しない）。 |
| 経路 | すべて CloudFront で受ける（確定）。画面は CloudFront → S3、発行と QR は CloudFront の `/v1/*` → API Gateway → Lambda（同じオリジンなので CORS は要らない）。 |
| Lambda と VPC・起動元 | 本番では `tickets` 関数を VPC（プライベートサブネット、NAT 経由で外へ）に入れる（確定。VPC の外で動かす構成は、テスト・開発用に残す）。QR 画像の `get-qr` は VPC の外で、どちらも起動の許可はその API Gateway だけ。 |
| アクセス数の上限 | API Gateway で、発行を 1時間 1 万件・1日 10 万件まで（確定。超えたら発行のルートを止め、次の時間の枠で戻す。`infra/cloudformation/quota-guard.yaml`）。1 秒あたりは 50 件・一時的に 100 件。WAF での制限も入れる予定（判断は後回し）。 |
| セキュリティグループ | 新しく作り、受信はなし・送信は HTTPS（443）だけだが、**宛先は 0.0.0.0/0** で、画像解析 API のネットワークには絞っていない。 |

## 画像サイズの超過で送れないケース

上限（4MB）を超えた写真は縮めて送るので、送れない（「画像のサイズが大きすぎます」）のは、縮められない HEIC が上限を超えたときだけ（詳しくは web/notes/image-compression.md 4.1.1）。

| ケース | 起きるか |
|---|---|
| Android の高画素モード（5000 万〜2 億画素）で、高効率（HEIF）で撮った写真 | **起きる**（Android のブラウザは HEIC を読めず、縮められない） |
| iPhone 14 Pro / Pro Max を iOS 16 のまま使い、4800 万画素の HEIC で撮った写真 | ほぼ起きない見込み（iOS 16 の標準は 1200 万画素で、4800 万画素の HEIC は iOS 17 からの設定。実機で要確認） |
| そのほかの iPhone（13 Pro 以前は HEIC が上限以下、15 シリーズ以降は iOS 17 以上で縮められる）と、すべての JPEG | 起きない |

## 未対応事項

2026-10-14 時点で、各ドキュメントに「未実装」「未検証」「要確認」「未確定」「保留」として残っているものを、種類ごとにまとめた。詳しくは各行の参照先。

### 確かめていないこと（実機・AWS 上）

| 項目 | 内容 | 参照 |
|---|---|---|
| 古い端末での動作 | iOS 13 の端末（またはクラウドの実機サービス）と、Android 9 の Chrome で動かしていない（ビルドの解析と最新の Chrome でだけ確かめた） | web/DESIGN.md 2.4 の 7 |
| 画像の圧縮の実機での動き | iPhone・Android での処理時間、写真の向き、HEIC。Android の高画素の JPEG（数千万〜2 億画素）がメモリ不足で縮められないことがあるか | web/notes/image-compression.md 7.1 |
| iPhone が HEIC のまま渡すか | 選択欄に `image/heic` を入れているので HEIC のまま渡ると見込んでいる。iPhone 14 Pro（iOS 16）の保存画素数も | web/notes/image-compression.md 4.1・4.1.1 |
| 発行の上限（1時間・1日）の動き | ルートのスロットリングを 0 にしたときに 429 になること、時間の枠の区切り方（1日は日本時間 9 時で区切られるか）、止めてから戻るまでの時間 | infra/RATE_LIMITING.md 7章 |
| 上限を超えた画像への API Gateway の応答 | Lambda まで届かない大きさ（約 4.5MB 超）のときのステータスと本文 | web/DEPLOY.md 12章 |
| AWS 上へのデプロイ | SAM のテンプレート（API・スタブ）、ネットワークのテンプレート、CloudFront の統合の構成、WAF の Web ACL、デプロイのワークフロー（`deploy.yml`）を AWS 上で動かしていない | infra/sam/README.md、notes/tickets-network.md 4.1、web/DEPLOY.md 3.2・13章、CI.md 4章 |
| E2E の範囲 | 画面遷移方式のケース1だけ。その場表示方式と、ほかのケース（CSRF など）は未実装 | E2E.md 7章 |

### 実装していないこと

| 項目 | 内容 | 参照 |
|---|---|---|
| Origin の照合 | ほかのサイトから発行させないための `ALLOWED_ORIGINS`（CSRF 対策） | infra/API_PROTECTION.md 2章 |
| セキュリティグループの宛先を絞る | 今は送信先が 0.0.0.0/0 の 443（NAT 経由で Parameter Store にも出るため。解析サーバーの CIDR で絞れるのは、ポートが 443 以外のときだけ）。解析サーバーのネットワークだけにするには、Parameter Store 用の VPC エンドポイントを置き、443 の宛先を `AnalyzerCidr` にする | notes/tickets-network.md 6章、`infra/cloudformation/tickets-network-*.yaml` |
| WAF | 入れる予定だが、判断は後回し（ルールと値、テンプレートにするか）。今は AWS CLI で作る手順の案だけ | web/DEPLOY.md 13章、infra/RATE_LIMITING.md |
| CloudFront を通らないアクセスを防ぐ | execute-api の URL を直接呼ばれると、CloudFront（と WAF）を迂回できる | infra/API_PROTECTION.md 3章 |
| Android の高画素の HEIF の案内 | 縮められず「大きすぎます」になったときに、撮り直しを案内する文言（案） | web/notes/image-compression.md 4.1.1 |
| デプロイを CodePipeline / CodeBuild に移す | 構成案だけ | CD_CI.md |
| 画面のアイコン（favicon） | 置いていない（ブラウザが取りに行って 404 になる。動作には影響しない） | - |

### 決めること

| 項目 | 内容 | 参照 |
|---|---|---|
| 画像解析サーバー | 置き場所・経路・許可の方式、接続先（URL・ポート・HTTP / HTTPS）、送るヘッダー、**縮めた写真（長辺 2048〜4096 の JPEG）で足りるか** | DESIGN.md 7章、notes/tickets-network.md 6章、web/notes/image-compression.md 7.2 |
| ネットワーク | 既存の VPC を使う（N1）か、すべて新しく作る（N2）か。Parameter Store への経路（NAT のままか、エンドポイントを足すか） | notes/tickets-network.md 6章 |
| Android の Chrome の下限 | 今は仮に 80（`browserslist` とビルドの出力先） | web/DESIGN.md 11章の 6 |
| 画面の文言・デザイン | バナーの画像は仮、発行画面の説明文とチケットの使い方の文言も仮 | web/DESIGN.md 3章・11章の 4 |
| その場表示方式の結果の保持 | リロードしても残すか（今は残さない） | web/DESIGN.md 11章の 1 |
| 独自ドメイン | Web と API に独自ドメインを付けるか | web/DESIGN.md 11章の 2、DEPLOY.md 4章 |
| 画像の圧縮の細かい点 | 上限以下の写真の EXIF も消すか、圧縮する条件を下げるか（例: 2MB 超） | web/notes/image-compression.md 7.2 |
| CI / CD の進め方 | CodePipeline の構成パターン、E2E をどこで流すか、本番のアカウント、承認者など | CD_CI.md 11章 |

### 保留にしていること

| 項目 | 内容 | 参照 |
|---|---|---|
| アップロードの進み具合 | 遅い環境には圧縮のほうが効くので保留 | web/notes/upload-progress.md |
| Android の「PC 版サイトを表示」 | User-Agent から Android が消え、「カメラを起動」が出ない | web/DESIGN.md 11章の 9 |
| CloudFront なしのテスト用の構成（構成 T） | テンプレートの分割とあわせて保留 | notes/adr-0001-cloudfront-split.md 7章 |

### ドキュメントの整理

| 項目 | 内容 |
|---|---|
| 古い記述 | web/DESIGN.md の冒頭と 2.1 の「状態」が、対応ブラウザについて「実装は保留」のまま（2.4 の 1〜5 は済み）。2.4 の 4 の「JS の `build.target` は未対応」も古い |
| 一時メモの片付け | 決着した一時メモ（web/notes/tailwind-compat.md、web/notes/builtin-compat.md）は、内容を設計書に反映済みなので削除できる。ほかの一時メモ（notes/ の検討メモ、web/notes/image-compression.md・upload-progress.md など）は、決まったら反映して削除する |
