# システム構成概要

稼働するシステムの構成要素だけを、1行ずつまとめる（デプロイの仕組みなどは書かない）。2026-10-13 時点で、`tw` ブランチ（Tailwind CSS 3.4）と `sh` ブランチ（画像の圧縮）が `master` にマージされた状態を前提にする（どちらもまだマージ前）。詳しくは [DESIGN.md](DESIGN.md)、[web/DESIGN.md](web/DESIGN.md)、[web/DEPLOY.md](web/DEPLOY.md)。

| 項目 | 現状 |
|---|---|
| 実装言語 | API は Go 1.27（`provided.al2023`）と Node.js 24（TypeScript）の2実装を Lambda（arm64）で動かし、画面は Vue 3.5 + TypeScript の SPA。 |
| 対応 OS | 仕様は iOS 13 以上 / Android 9 以上で、CSS は対応済み（Tailwind CSS 3.4）だが、**JS はまだ満たしていない**（トップレベルの `await`、`AbortSignal.timeout()` などが残り、実機での確認もしていない）。 |
| 画像サイズ上限 | 4MiB（4,194,304 バイト）が上限で、環境ごとに下げられる（API の `MAX_IMAGE_BYTES` と SPA の `maxImageBytes`）。 |
| 画像圧縮 | 上限を超えた写真だけ、SPA が Compressor.js で JPEG に縮めてから送る（画面遷移方式・その場表示方式のみ。上限以下はそのまま送り、API 側は加工しない）。 |
| 経路 | 「CloudFront → S3（画面）＋ブラウザ → API Gateway → Lambda（直結）」と「CloudFront の `/*` → S3、`/v1/*` → API Gateway → Lambda（統合）」をパラメータで切り替える。 |
| Lambda と VPC・起動元 | VPC に入るのは `tickets` 関数だけ（QR 画像の `get-qr` は VPC の外）で、どちらも起動の許可はその API Gateway だけ。ただし API Gateway の URL は CloudFront を通さずにも呼べる。 |
| セキュリティグループ | 新しく作り、受信はなし・送信は HTTPS（443）だけだが、**宛先は 0.0.0.0/0** で、画像解析 API のネットワークには絞っていない。 |

## 画像サイズの超過で送れないケース

上限（4MB）を超えた写真は縮めて送るので、送れない（「画像のサイズが大きすぎます」）のは、縮められない HEIC が上限を超えたときだけ（詳しくは web/notes/image-compression.md 4.1.1）。

| ケース | 起きるか |
|---|---|
| Android の高画素モード（5000 万〜2 億画素）で、高効率（HEIF）で撮った写真 | **起きる**（Android のブラウザは HEIC を読めず、縮められない） |
| iPhone 14 Pro / Pro Max を iOS 16 のまま使い、4800 万画素の HEIC で撮った写真 | ほぼ起きない見込み（iOS 16 の標準は 1200 万画素で、4800 万画素の HEIC は iOS 17 からの設定。実機で要確認） |
| そのほかの iPhone（13 Pro 以前は HEIC が上限以下、15 シリーズ以降は iOS 17 以上で縮められる）と、すべての JPEG | 起きない |

- フォーム送信方式は縮める処理がないので、上限を超えた写真はすべて送れない（API のエラーページになる）

## 想定との違い

想定（「対応 OS を満たす」「Lambda は API Gateway 経由でだけ動く」「セキュリティグループの送信は、画像解析 API のネットワークへの HTTPS だけ」）と、今の実装の違い。

| 項目 | 違い | 合わせるには |
|---|---|---|
| 対応 OS | CSS は対応済み（Tailwind CSS 3.4）だが、JS は要件を満たしていない | JS の対応（web/DESIGN.md 2.4 の 1〜3・5。ビルドの出力先、トップレベルの `await`、`AbortSignal.timeout()`、組み込みの機能の確認）、実機での確認 |
| セキュリティグループ | 送信先が 0.0.0.0/0。NAT 経由で Parameter Store にも 443 で出るため。解析サーバーの CIDR（`AnalyzerCidr`）で絞れるのは、ポートが 443 以外のときだけ | Parameter Store 用の VPC エンドポイントを置き、443 の宛先を `AnalyzerCidr` にする（`infra/cloudformation/tickets-network-*.yaml` の変更） |
| 起動元 | Lambda を起動できるのは API Gateway だけだが、API Gateway の URL は CloudFront を通さずに直接呼べる（WAF などを迂回できる） | 秘密のヘッダーの照合、または独自ドメインと `DisableExecuteApiEndpoint`（web/DEPLOY.md 11章。未実装） |
