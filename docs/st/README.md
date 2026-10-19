# システム構成概要

稼働するシステムの構成要素だけを、1行ずつまとめる（デプロイの仕組みなどは書かない）。設定で切り替えられる項目は、既定の構成だけを書く（2026-10-14 時点の `master`）。詳しくは [DESIGN.md](DESIGN.md)、[web/DESIGN.md](web/DESIGN.md)、[web/DEPLOY.md](web/DEPLOY.md)。

| 項目 | 現状 |
|---|---|
| 実装言語 | API は Go 1.27 で、Lambda（`provided.al2023`、arm64）で動かす。画面は Vue 3.5 + TypeScript の SPA。 |
| API の Node.js 実装 | 比較用に Node.js（TypeScript）版の API もある（採用は Go。説明はすべて [node/](node/README.md) にまとめた）。 |
| 対応 OS | iOS 13 以上 / Android 9 以上。 |
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
| iPhone 14 Pro / Pro Max を iOS 16 のまま使い、4800 万画素の HEIC で撮った写真 | ほぼ起きない見込み（iOS 16 の標準は 1200 万画素で、4800 万画素の HEIC は iOS 17 からの設定） |
| そのほかの iPhone（13 Pro 以前は HEIC が上限以下、15 シリーズ以降は iOS 17 以上で縮められる）と、すべての JPEG | 起きない |

## 未対応事項

確かめていないこと・実装していないこと・決めること・保留していることは、[OPEN_ITEMS.md](OPEN_ITEMS.md) にまとめている。
