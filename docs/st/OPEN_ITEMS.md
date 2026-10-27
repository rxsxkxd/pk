# 未対応事項

確かめていないこと・実装していないこと・決めること・保留していることを、**ここにだけ**まとめる（2026-10-19）。ほかのドキュメントは、仕様と手順（決まったこと・できていること）だけを書く。片付いたら、この一覧から消し、内容を該当のドキュメントに反映する。

- 「関連」の列は、その事項の仕様・手順・検討が書いてある場所
- 検討メモ（`notes/`・`web/notes/`）は、検討の途中の記録なので、本文に未決の事項を含む（6章）
- API の Node 版（比較用）は対象外（`node/` の中で完結させている）

## 1. 確かめていないこと（実機・AWS 上）

| 項目 | 内容 | 関連 |
|---|---|---|
| 古い端末での動作 | iOS 13 の端末（またはクラウドの実機サービス）と、Android 9 の Chrome で動かしていない（ビルドの解析と最新の Chrome でだけ確かめた）。テストの項目からも外して保留にしている（4章） | web/DESIGN.md 2.4 |
| 画像の圧縮の実機での動き | iPhone・Android での処理時間、写真の向き、HEIC。Android の高画素の JPEG（数千万〜2 億画素）がメモリ不足で縮められないことがあるか | web/notes/image-compression.md 7.1 |
| iPhone が HEIC のまま渡すか | 選択欄に `image/heic` を入れているので HEIC のまま渡ると見込んでいる。iPhone 14 Pro（iOS 16）の保存画素数も | web/DESIGN.md 3章、web/SCREENS.md、web/notes/image-compression.md 4.1・4.1.1 |
| Android の「PC 版サイトを表示」での端末の判定 | `navigator.userAgentData.platform` と `navigator.platform` が何を返すか | web/DESIGN.md 3章 |
| 発行の上限（1時間・1日）の動き | ルートのスロットリングを 0 にしたときに 429 になること、時間の枠の区切り方（1日は日本時間 9 時で区切られるか）、止めてから戻るまでの時間 | infra/RATE_LIMITING.md 7章、aws-test/PLAN.md 3.3 |
| 上限を超えた画像への API Gateway の応答 | Lambda まで届かない大きさ（約 4.5MB 超・10MB 超）のときのステータスと本文。結果を見て SPA の扱いを決める（3.3） | web/DEPLOY.md 12章、DESIGN.md 5章の経路ごとの上限の表 |
| API Gateway HTTP API の HTTP/2 | execute-api のエンドポイントが HTTP/2 で応答するか（アップロードの進み具合を出す場合に要る。4章の保留） | web/DESIGN.md 2.3 |
| AWS 上へのデプロイ | 次のものを AWS 上で動かしていない: SAM のテンプレート（API・スタブ・ダミーの解析サーバー）、ネットワークのテンプレート、CloudFront の統合の構成、発行の上限（quota-guard）、WAF の Web ACL | infra/sam/README.md、infra/PROD_DEPLOY.md、notes/tickets-network.md 4.1、web/DEPLOY.md 3.2・13章、analyzer-stub/DESIGN.md 7章、dummy-analyzer/README.md |
| CD パイプライン | `pipeline.yaml` のスタックを AWS 上で作っていない。CodeBuild の上で `GOTOOLCHAIN=auto` が `go.mod` の Go を取れること、goenv の更新と Go 1.26.10 の導入が通ること、GitHub との接続（CodeConnections）、Deploy の段の権限が足りることも未確認 | cd/README.md 9章、infra/CD_PIPELINE.md |
| GitHub 上での CI | 単体テストだけに絞ったワークフロー（2026-10-23）は、手元の act でだけ流した（成功）。GitHub 上ではまだ動かしていない（専用のリポジトリへの push 前）。スタブの CI は act でも未確認 | ci/README.md 5章 |
| 本番環境向けの検証 | PROD_VERIFICATION.md の手順（ダミーの解析サーバーを含む）を AWS 上で流していない | PROD_VERIFICATION.md、TEST_PROCEDURES.md |
| テストの未実施の項目 | TEST_RESULT.md で実施日が空の項目 | TEST_RESULT.md、TEST_PROCEDURES.md |

## 2. 実装していないこと

| 項目 | 内容 | 関連 |
|---|---|---|
| Origin の照合 | ほかのサイトから発行させないための `ALLOWED_ORIGINS`（CSRF 対策）。QR 同梱付与 API とチケット付与 API で `Origin` を照合し、違えば 403。環境変数 `ALLOWED_ORIGINS`・CloudFormation の `AllowedOrigins`。実装したら、デプロイの手順とワークフローで SPA のオリジンを渡す | infra/API_PROTECTION.md 2章、E2E.md 4.2、web/DESIGN.md 7章 |
| CORS の設定のテンプレート化 | 直結の構成の CORS は、今は `aws apigatewayv2 update-api` でスタックの外から設定している。`api.yaml` に `AllowedOrigins` パラメータと `CorsConfiguration` を足し、手順書の CORS の手順を消す | web/DEPLOY.md 5章 |
| CloudFront を通らないアクセスを防ぐ | execute-api の URL を直接呼ばれると、CloudFront（と WAF）を迂回できる（秘密のヘッダー、独自ドメイン + `DisableExecuteApiEndpoint` など） | infra/API_PROTECTION.md 3章、web/DEPLOY.md 11章 |
| WAF | 入れる予定だが、判断は後回し。今は Web ACL の案と AWS CLI で作る手順だけ（テンプレートにはしていない） | web/DEPLOY.md 13章、infra/RATE_LIMITING.md |
| セキュリティグループの宛先を絞る | 今は送信先が 0.0.0.0/0 の 443（NAT 経由で Parameter Store にも出るため。解析サーバーの CIDR で絞れるのは、ポートが 443 以外のときだけ）。解析サーバーのネットワークだけにするには、Parameter Store 用の VPC エンドポイントを置き、443 の宛先を `AnalyzerCidr` にする | notes/tickets-network.md 6章、`infra/cloudformation/tickets-network-*.yaml` |
| 独自ドメイン | Web: CloudFront の代替ドメイン名と us-east-1 の ACM 証明書を `web.yaml` に足す（直結では CORS の `AllowOrigins`、統合では API の `PublicBaseUrl` も独自ドメインにする）。API: `PublicBaseUrl` のパラメータだけあり、ACM 証明書・`AWS::ApiGatewayV2::DomainName`・`ApiMapping` はない | DEPLOY.md、web/DEPLOY.md |
| 本物の画像解析サーバーへの接続 | HTTP クライアントは仮のプロトコル（analyzer-stub/DESIGN.md 3章）で実装済み。本物の仕様が決まったら、応答の解釈（`parseResponse`）を差し替える。VPC の設定が要る可能性がある | DESIGN.md 7章、analyzer-stub/DESIGN.md 3章 |
| スタブの判定の切り替え | 画像の目印で REJECT・RETRY・失敗・遅延を返す案（検証環境では、代わりにダミーの解析サーバーを使える） | analyzer-stub/DESIGN.md 4章、dummy-analyzer/README.md |
| Android の高画素の HEIF の案内 | 縮められず「大きすぎます」になったときに、撮り直しを案内する文言（案） | web/notes/image-compression.md 4.1.1 |
| E2E のほかのケース | 画面遷移方式のケース1だけ。その場表示方式と、ほかのケース（CSRF など）、QR の中身の確認（デコードしてコードと照合）、解析サーバーのスタブを使う回、画像の縮小（4MB を超える写真）。E2E のブラウザ（Chromium）は最新の版で、古い iOS・Android の動きは再現しない。本番側の CloudFormation への CORS（`AllowedOrigins`）も | E2E.md 5章 |
| AWS 環境に対するテスト | 計画だけで、コードはない（試験用の環境と認証情報がない） | aws-test/PLAN.md |
| CD パイプラインの E2E の段 | 何もしない空のビルドを置いただけ。compose の E2E を CodeBuild で流すか、デプロイ後に本物の環境に対して流すか | cd/README.md 6章 |
| CD パイプラインの本番 | パイプラインは 1 つの環境（Dev 相当）だけ。本番の環境、承認の段、失敗の通知（SNS）はない | cd/README.md、cd/PATTERNS.md 4.1・8章 |
| CI のキャッシュ | スタブ（Rust）のビルド（`actions/cache` で cargo のディレクトリ）をキャッシュしていない | analyzer-stub/github-template/README.md |

## 3. 決めること

### 3.1 API の仕様

| 項目 | 内容 | 関連 |
|---|---|---|
| ピーク時の発行量 | 1 秒あたりの件数と、許容するコードの衝突の確率 | DESIGN.md 4章 |
| 同じ画像の繰り返しの送信 | 防ぐ必要があるか | DESIGN.md 6章 |
| チケット表示ページの URL の有効期限 | 要るか | DESIGN.md 5章 |
| QR 同梱付与 API の認証 | API キー / JWT（Cognito など）/ IAM のどれか（チケット付与 API は認証なしで決定） | DESIGN.md 10章 |
| チケット表示ページのデザイン・文言 | 今は最小構成の例 | DESIGN.md 5章 |

### 3.2 画像解析サーバー

| 項目 | 内容 | 関連 |
|---|---|---|
| 接続の方法 | 置き場所・経路・許可の方式、接続先（URL・ポート・HTTP / HTTPS）、送るヘッダー（画像の形式やファイル名などのメタデータを送るか）、応答の形式と認証（仮の形式・認証で進めてよいか） | DESIGN.md 7章、analyzer-stub/DESIGN.md 3章、notes/tickets-network.md 6章 |
| 縮めた写真で足りるか | 長辺 2048〜4096 の JPEG で判定できるか | web/notes/image-compression.md 7.2 |
| 受けられる量 | 1 秒あたり・同時の数。API の上限と予約同時実行数の根拠になる | infra/RATE_LIMITING.md 5章 |

### 3.3 画面

| 項目 | 内容 | 関連 |
|---|---|---|
| Android の Chrome の下限 | 今は仮に 80（`browserslist` とビルドの出力先）。Android 9 の Chrome は 138 で更新が止まっている | web/DESIGN.md 2.1 |
| 画面の文言・デザイン | バナーとアイコン（favicon）の画像は仮（置き換える前提。web/DEPLOY.md 6.1）。発行画面の説明文・補足事項とチケットの使い方の文言も仮。エラーの文言を TEST_RESULT.md の期待結果に合わせて変えるか | web/DESIGN.md 3章、TEST_RESULT.md 3.2 |
| その場表示方式の結果の保持 | リロードしても残すか（今は残さない） | web/DESIGN.md 4章 |
| 発行の上限に達したときの文言 | 今は「発行できませんでした」。429 なら「ただいま混み合っています」にするか | infra/RATE_LIMITING.md 7章 |
| Lambda に届かない大きさの画像の扱い | API Gateway の応答（1章）を見て、413 を「画像のサイズが大きすぎます」にするかなど | web/DEPLOY.md 12章 |
| 画像の圧縮の細かい点 | 上限以下の写真の EXIF も消すか、圧縮する条件を下げるか（例: 2MB 超） | web/notes/image-compression.md 7.2 |

### 3.4 ネットワーク・保護・上限

| 項目 | 内容 | 関連 |
|---|---|---|
| ネットワーク | 既存の VPC を使う（N1）か、すべて新しく作る（N2）か。Parameter Store への経路（NAT のままか、エンドポイントを足すか） | notes/tickets-network.md 6章 |
| 独自ドメイン | Web と API に独自ドメインを付けるか | DEPLOY.md、web/DEPLOY.md |
| Origin の照合 | 入れるか、どこで行うか（Go / CloudFront Functions / WAF）、`Origin` がない要求を通すか（推奨: 通す。E2E の検討では拒否を推奨していた）、入れる時期 | infra/API_PROTECTION.md 2章、E2E.md 4章 |
| CloudFront を通らないアクセス | 防ぐか、方法（秘密のヘッダー / Lambda の認可の関数） | infra/API_PROTECTION.md 3章 |
| WAF | 入れるか、ルール（web/DEPLOY.md 13.1 の案でよいか）、送信元 IP ごとのレート制限の値（仮に 5 分 100 回）、料金、テンプレートにするか（us-east-1 の別のテンプレート）か AWS CLI で作るか | web/DEPLOY.md 13章、infra/API_PROTECTION.md、infra/RATE_LIMITING.md 5章 |
| 発行のルートの 1 秒あたりの上限 | 発行のルートだけに別の値を付けるか（今はすべてのルートが 50 / 100） | infra/RATE_LIMITING.md 5章 |
| CORS を先に実装するか | 直結の構成の CORS と Origin の照合を、フロントエンドより先に行ってよいか | web/DESIGN.md 7章、E2E.md 4章 |
| 検索エンジンに載せない設定の細部 | `noarchive` まで付けるか（今は付けている）。`robots.txt` を置くか（置くなら、AI の学習用のクローラーだけを断る中身にし、デプロイで `no-cache` で上げる） | infra/NOINDEX.md 2.2.1 |

### 3.5 CI / CD・テスト

| 項目 | 内容 | 関連 |
|---|---|---|
| E2E をどこで流すか | GitHub Actions の模擬環境（E1）、AWS の本物に近い環境（E2）、両方（E3）（推奨: E3）。CI のトリガー（PR ごとか、変わったファイルで絞るか） | cd/PATTERNS.md 0.5、E2E.md 6章 |
| 本番の環境 | 同じ AWS アカウントでスタック名を分けるか、別のアカウントにするか（推奨: 別のアカウント） | cd/PATTERNS.md |
| Dev への反映 | master への push ごとに自動にするか（推奨: 自動） | cd/PATTERNS.md |
| 承認者と通知先、リリースの記録を残す期間 | - | cd/PATTERNS.md |
| CD の控えと構成のずれ | 控え（`releases/`・`web-releases/`）をいつまで残すか（今は消さない）、構築を別のパイプラインにするか（今は手順書）、テンプレートと実環境のずれの見つけ方 | cd/README.md 4・7章、cd/UPDATE_ONLY.md 6・7章 |
| AWS 環境に対するテスト | 試験用の環境を持つか（持たないなら A だけを本番のデプロイの後に流す）、C-7（1 秒あたりの上限に負荷をかける）を流すか、A-9 の期待値、WAF を入れたときの確認 | aws-test/PLAN.md |
| E2E の方式の切り替えの基準 | RIE + ゲートウェイの方式が難しくなったら、ローカルモードに切り替える判断の基準 | E2E.md 2章 |

## 4. 保留していること

| 項目 | 内容 | 関連 |
|---|---|---|
| アップロードの進み具合 | 遅い環境には圧縮のほうが効くので保留（出すなら Android だけ Fetch Upload Streams。HTTP/2 が要る） | web/DESIGN.md 2.3、web/notes/upload-progress.md |
| Android の「PC 版サイトを表示」 | User-Agent から Android が消え、「カメラを起動」が出ない。`matchMedia('(pointer: coarse)')` を判定に足す案は、iPhone・iPad にもボタンが2つ出るので保留 | web/DESIGN.md 3章 |
| 古いブラウザへの対応のテスト | 実機（iOS 13 / Android 9）での確認を、テストの項目（TEST_SCOPE.md 2章）から外して保留（2026-10-15）。確かめること: iOS 13 の Safari と Android 9 の Chrome（80）で、画面が表示され（真っ白にならない）、スタイルが付き、画像を選んで発行し、チケット画面に QR が出る。自動のテストは web の `main-imports` とビルド。再開するときは TEST_SCOPE.md 2章の表に戻す | web/DESIGN.md 2.4 |
| CloudFront なしのテスト用の構成（構成 T） | テンプレートの分割とあわせて保留 | notes/adr-0001-cloudfront-split.md 7章 |

## 5. ドキュメントの整理

| 項目 | 内容 |
|---|---|
| 一時メモの片付け | 決着した一時メモ（web/notes/tailwind-compat.md、web/notes/builtin-compat.md）は、内容を設計書に反映済みなので削除できる。ほかの一時メモ（6章）は、決まったら反映して削除する |

## 6. 検討メモ（未決の事項を本文に含む一時メモ）

| メモ | 中身 |
|---|---|
| [notes/tickets-network.md](notes/tickets-network.md) | `tickets` のネットワークの2パターン（N1・N2）と、決めること（6章） |
| [notes/lambda-vpc.md](notes/lambda-vpc.md) | Lambda を VPC に入れるときの検討（経緯） |
| [notes/analyzer-stub-vpc.md](notes/analyzer-stub-vpc.md) | VPC 版のスタブの置き方の検討 |
| [notes/cloudfront-split.md](notes/cloudfront-split.md)・[notes/adr-0001-cloudfront-split.md](notes/adr-0001-cloudfront-split.md) | CloudFront の構成の分け方と ADR の下書き |
| [notes/analyzer-stub-cost.md](notes/analyzer-stub-cost.md) | スタブの費用 |
| [web/notes/image-compression.md](web/notes/image-compression.md) | 画像の圧縮の検討と残り（7章） |
| [web/notes/upload-progress.md](web/notes/upload-progress.md) | アップロードの進み具合（保留） |
| [web/notes/client-logic.md](web/notes/client-logic.md)・[web/notes/error-messages.md](web/notes/error-messages.md) | 画面の処理の置き場所、エラーの文言の検討 |

## 7. 解決したので外したもの

以前の「要確定事項」（DESIGN.md）にあったが、実装で決まったもの。

| 項目 | 決まったこと |
|---|---|
| コードの固定文字列のルール | 英数字 1〜32 文字。Parameter Store に置く（CHANGES.md） |
| 日時のタイムゾーンと精度 | 日本時間、秒まで |
| QR のペイロード | コード |
| 入力画像の対応形式とサイズ上限 | JPEG / PNG / HEIC / HEIF / AVIF / WebP、4MiB |
| IaC ツール | CloudFormation（と SAM） |
| CD の構成（2026-10-22） | CodePipeline / CodeBuild。master への push で開始し、CodeBuild がソースから単体テストとビルドを行い、デプロイは Lambda のコードと SPA のファイルの差し替えだけ（cd/README.md） |
| CI と CD の置き場所（2026-10-23） | CI（GitHub Actions。コミットごとの単体テストだけ）は `ci/`、CD（buildspec・デプロイのスクリプト・手順）は `cd/`、パイプラインのテンプレートも `cd/`（`cd/pipeline.yaml`）。`infra/` には CI / CD のものは最初の環境構築の手順書（infra/CD_PIPELINE.md）だけを置く。GitHub Actions からデプロイする案は採らない（cd/GITHUB_ACTIONS.md に記録だけ残す） |
