# システム構成概要

稼働するシステムの構成要素だけを、1行ずつまとめる（デプロイの仕組みなどは書かない）。設定で切り替えられる項目は、既定の構成だけを書く（2026-10-13 時点。`tw` ブランチ（Tailwind CSS 3.4）と `sh` ブランチ（画像の圧縮）がマージされた状態）。詳しくは [DESIGN.md](DESIGN.md)、[web/DESIGN.md](web/DESIGN.md)、[web/DEPLOY.md](web/DEPLOY.md)。

| 項目 | 現状 |
|---|---|
| 実装言語 | API は Go 1.27 で、Lambda（`provided.al2023`、arm64）で動かす。画面は Vue 3.5 + TypeScript の SPA。 |
| 対応 OS | 仕様は iOS 13 以上 / Android 9 以上で、CSS は対応済み（Tailwind CSS 3.4）だが、JS も、構文の変換・トップレベルの `await`・`AbortSignal.timeout()`・`Object.hasOwn` は対応済みだが、**iOS 13 では zod が読み込み時に `BigInt` を使って画面が真っ白になる**（対応は保留）。実機での確認もしていない。 |
| 画像サイズ上限 | 4MiB（4,194,304 バイト）。 |
| 画像圧縮 | 上限を超えた写真だけ、SPA が Compressor.js で JPEG に縮めてから送る（上限以下はそのまま送り、API 側は加工しない）。 |
| 経路 | 画面は CloudFront → S3、発行と QR はブラウザ → API Gateway → Lambda。 |
| Lambda と VPC・起動元 | 本番では `tickets` 関数を VPC（プライベートサブネット、NAT 経由で外へ）に入れる（確定。VPC の外で動かす構成は、テスト・開発用に残す）。QR 画像の `get-qr` は VPC の外で、どちらも起動の許可はその API Gateway だけ。 |
| セキュリティグループ | 新しく作り、受信はなし・送信は HTTPS（443）だけだが、**宛先は 0.0.0.0/0** で、画像解析 API のネットワークには絞っていない。 |

## 画像サイズの超過で送れないケース

上限（4MB）を超えた写真は縮めて送るので、送れない（「画像のサイズが大きすぎます」）のは、縮められない HEIC が上限を超えたときだけ（詳しくは web/notes/image-compression.md 4.1.1）。

| ケース | 起きるか |
|---|---|
| Android の高画素モード（5000 万〜2 億画素）で、高効率（HEIF）で撮った写真 | **起きる**（Android のブラウザは HEIC を読めず、縮められない） |
| iPhone 14 Pro / Pro Max を iOS 16 のまま使い、4800 万画素の HEIC で撮った写真 | ほぼ起きない見込み（iOS 16 の標準は 1200 万画素で、4800 万画素の HEIC は iOS 17 からの設定。実機で要確認） |
| そのほかの iPhone（13 Pro 以前は HEIC が上限以下、15 シリーズ以降は iOS 17 以上で縮められる）と、すべての JPEG | 起きない |

## 想定との違い

想定（「対応 OS を満たす」「セキュリティグループの送信は、画像解析 API のネットワークへの HTTPS だけ」）と、今の実装の違い。

| 項目 | 違い | 合わせるには |
|---|---|---|
| 対応 OS | CSS と JS の大半は対応済みだが、zod 4 の `BigInt` で iOS 13 は動かない | zod を valibot か zod 3 に替える（web/DESIGN.md 2.4 の 5、web/notes/builtin-compat.md。保留中）、実機での確認 |
| セキュリティグループ | 送信先が 0.0.0.0/0。NAT 経由で Parameter Store にも 443 で出るため。解析サーバーの CIDR（`AnalyzerCidr`）で絞れるのは、ポートが 443 以外のときだけ | Parameter Store 用の VPC エンドポイントを置き、443 の宛先を `AnalyzerCidr` にする（`infra/cloudformation/tickets-network-*.yaml` の変更） |
