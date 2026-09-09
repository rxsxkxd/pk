# image-mask

S3 に置かれた画像の**上半分にガウスぼかしを適用**して、別バケットへ保存する Lambda。

- 言語: Go 1.24 / `provided.al2023` / arm64
- IaC: AWS SAM（`template.yaml`）
- 設計: [docs/image-blur-lambda-design.md](docs/image-blur-lambda-design.md)

```
s3://…-raw/uploads/2026/09/doc.jpg
        │  ObjectCreated 通知
        ▼
   Lambda (image-mask)  ── 失敗 ──▶ SQS DLQ
        │
        ▼
s3://…-out/masked/v1/2026/09/doc.jpg   ← 上半分だけぼけた画像
```

## 構成

| パス | 内容 |
|---|---|
| `cmd/mask` | Lambda エントリポイント |
| `internal/handler` | S3 イベント処理の本体（検証・冪等性・fail-closed） |
| `internal/imaging` | ぼかし、領域切り出し、EXIF 向き補正、強度測定 |
| `internal/config` | 環境変数の読み込み |
| `internal/metrics` | EMF によるカスタムメトリクス出力 |
| `template.yaml` | バケット・KMS・Lambda・DLQ・CloudTrail・アラーム |

## 使い方

```bash
make test      # go test ./... -race
make validate  # sam validate --lint
make deploy    # sam build && sam deploy --guided
```

デプロイ後、出力された `RawBucketName` の `uploads/` 配下に画像を置くと、
`MaskedBucketName` の `masked/v1/…` に結果が出る。

```bash
aws s3 cp photo.jpg s3://$RAW_BUCKET/uploads/photo.jpg
aws s3 cp s3://$MASKED_BUCKET/masked/v1/photo.jpg ./masked.jpg
```

## 設計上の要点

### マスク領域は上半分固定

検出処理（Rekognition / OCR）は使わず、常に画像上部の矩形をマスクする。
比率は `MASK_HEIGHT_RATIO` で変更でき、`1.0` にすれば全面マスクになる。

### ぼかし半径は寸法比で決まる

半径を絶対値で固定すると、大きい画像でマスクが実質的に効かなくなる
（8000px の画像に半径 8px を当てても文字は読める）。
常に**短辺 × `MIN_BLUR_RATIO`（既定 4%）**で算出し、アップローダ側からは指定できない。

| 画像 | 半径 |
|---|---|
| 4000 × 3000 | 120 px |
| 800 × 600 | 24 px |
| 200 × 150 | 8 px（下限） |

大きな半径でも速度が落ちないよう、ぼかしはボックスぼかし 3 回の重ね掛けで
ガウス分布を近似している（半径によらず O(pixels)）。

### 出力前に強度を自己検証する（fail-closed）

マスク**領域だけ**のラプラシアン分散を測り、`MAX_ALLOWED_LAPLACIAN_VAR` を超えたら
`PutObject` を行わずにエラーを返す（イベントは DLQ へ）。
パラメータ誤設定で「実質マスクされていない画像」が出力される事故を構造的に防ぐ。

画像全体ではなく領域だけを測るのが要点。全体で測ると、鮮明なままの下半分に
引きずられて正常な入力まで DLQ に落ちる。

### メタデータは完全に除去される

JPEG の EXIF には**未加工の縮小プレビュー**が埋め込まれていることがあり、
これが残ると本体をぼかす意味がなくなる。Go の標準エンコーダは EXIF / XMP を
一切書き出さないため、再エンコードした時点で構造的に除去される。
向き情報だけは失われるので、デコード直後に Orientation を読んで画素へ反映している。

### 冪等性

S3 イベント通知は at-least-once。出力キーは入力キーとポリシー版から決定的に決まり、
書き込み前に出力側の `source-etag` を確認して二重処理を避ける。

## 環境変数

| 名前 | 既定 | 説明 |
|---|---|---|
| `OUTPUT_BUCKET` | （必須） | 出力先バケット |
| `INPUT_PREFIX` | `uploads/` | 入力プレフィックス |
| `OUTPUT_PREFIX` | `masked/` | 出力プレフィックス |
| `MASKING_POLICY_VERSION` | `v1` | 出力キーに含まれるポリシー版 |
| `MASK_HEIGHT_RATIO` | `0.5` | 上部からマスクする高さの比率 |
| `MIN_BLUR_RATIO` | `0.04` | 短辺に対するぼかし半径の比率 |
| `MIN_BLUR_RADIUS_PX` | `8` | 半径の絶対下限 |
| `DOWNSCALE_FACTOR` | `1` | 追加ハードニング用の縮小率（1 で無効） |
| `MAX_ALLOWED_LAPLACIAN_VAR` | `5.0` | 強度検証のしきい値 |
| `MAX_INPUT_BYTES` | `20971520` | 入力サイズ上限 |
| `MAX_INPUT_PIXELS` | `64000000` | 総ピクセル数上限 |
| `JPEG_QUALITY` | `85` | JPEG 出力品質 |
| `LOG_LEVEL` | `INFO` | ログレベル |

## 未実装 / 既知の制限

- **対応形式は JPEG / PNG のみ。** Go 標準ライブラリに WebP エンコーダがないため、
  WebP は検証エラーとして DLQ に送られる。対応するなら `golang.org/x/image/webp`
  （デコードのみ）+ 別形式での出力か、cgo を伴うエンコーダの導入が必要。
- **`MAX_ALLOWED_LAPLACIAN_VAR` は暫定値（5.0）。** 実データ 1,000 枚程度で
  分布を取ってから決めること。厳しすぎると正常画像が DLQ に落ちる。
- **アニメーション画像**（GIF / APNG / animated WebP）は非対応。
- CloudTrail のログバケットに Object Lock を設定していない（設計書 §11.3）。
