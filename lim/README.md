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
| `cmd/maskfile` | ローカル実行用 CLI（S3 不要） |
| `internal/handler` | S3 イベント処理（検証・冪等性・fail-closed） |
| `internal/masking` | マスキング処理そのもの。Lambda と CLI が共有する |
| `internal/imaging` | ぼかし、領域切り出し、EXIF 向き補正、強度測定 |
| `internal/config` | 環境変数の読み込み |
| `internal/metrics` | EMF によるカスタムメトリクス出力 |
| `template.yaml` | バケット・KMS・Lambda・DLQ・CloudTrail・アラーム |

## 必要なもの

| | ローカル実行 | デプロイ |
|---|---|---|
| Go 1.24 以降 | 必須 | 必須 |
| AWS アカウント / 認証情報 | 不要 | 必須 |
| SAM CLI | 不要 | 必須 |
| Docker | 不要 | 不要 |

外部依存は `aws-lambda-go` と `aws-sdk-go-v2` のみ。画像処理は標準ライブラリだけで
実装しているため、`go test` / `go run` は初回の依存取得以外にセットアップが要らない。

## ローカルで試す

AWS アカウントも Docker も不要。`cmd/maskfile` が Lambda と同じ
`internal/masking` を呼ぶため、ここで得られる結果は本番と一致する。

```bash
go run ./cmd/maskfile -out masked.jpg photo.jpg
# または
make run IN=photo.jpg OUT=masked.jpg
```

```
photo.jpg  jpeg 1200x900  radius=36px  top 50% (0,0,1200,450)
           score=0.0508 (limit 5.0, ok)  111KB->28KB  87ms
           -> masked.jpg
```

まとめて処理する場合と、しきい値を調整する場合:

```bash
# 複数ファイルを出力ディレクトリへ
go run ./cmd/maskfile -out-dir ./out ./samples/*.jpg

# 出力は書かずスコアだけ集める（MAX_ALLOWED_LAPLACIAN_VAR の決定用）
go run ./cmd/maskfile -report-only -json ./samples/*.jpg | jq -s 'map(.strengthScore) | max'

# 領域やぼかしの強さを変えて確認
go run ./cmd/maskfile -mask-height-ratio 0.6 -blur-ratio 0.06 -out out.jpg photo.jpg
```

強度検証に落ちた場合とデコードに失敗した場合は、本番で DLQ に入るのと同じ分類が
表示され、終了コードが 1 になる。

```
broken.jpg  FAILED (validation) cannot decode image header: image: unknown format
photo.jpg   FAILED (strength) mask strength check failed: laplacian variance 10396.924 > 5.000
```

### 確認すべき 3 点

1. **上半分の内容が判別できないこと** — 隠したい情報が読めないか
2. **下半分が変化していないこと** — にじみ・色ずれがないか
3. **`score` が `limit` に対して十分小さいこと** — どれだけ余裕があるか

### リリース前に必ずやること

`MAX_ALLOWED_LAPLACIAN_VAR = 5.0` は**根拠のない暫定値**。厳しすぎれば正常画像が
全件 DLQ に落ち、緩すぎれば弱いマスクが素通りする。実データで分布を取ってから決める。

```bash
go run ./cmd/maskfile -report-only -json ./samples/*.jpg > scores.jsonl
jq -s 'map(.strengthScore) | {max: max, p99: (sort | .[(length*0.99|floor)])}' scores.jsonl
```

詳細は[設計書 §14.1](docs/image-blur-lambda-design.md)。

## テストとデプロイ

```bash
make test      # go test ./... -race
make validate  # sam validate --lint（SAM CLI が必要）
make deploy    # sam build && sam deploy --guided
```

デプロイ後、出力された `RawBucketName` の `uploads/` 配下に画像を置くと、
`MaskedBucketName` の `masked/v1/…` に結果が出る。

```bash
aws s3 cp photo.jpg s3://$RAW_BUCKET/uploads/photo.jpg
aws s3 cp s3://$MASKED_BUCKET/masked/v1/photo.jpg ./masked.jpg
```

## 前提としていること

この実装は以下を**前提**にしている。崩れると設計が成立しない。
全項目と確認状況は[設計書 §3.1](docs/image-blur-lambda-design.md) にある。

- **隠したい情報は常に画像の上半分にある。**
  検出処理を使わないため検出漏れは起こらないが、対象が下半分に写っていた場合は
  **何も検知されずに露出する**。技術的な緩和策はなく、入力側の運用で担保するしかない。
- 入力は JPEG / PNG のみ（WebP は現状 DLQ 行き）。
- 1 枚あたり 20 MB / 8000 × 8000 px 以内。
- ラプラシアン分散 5.0 というしきい値が正常・異常を分離できる（**未検証**）。

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

### ローカルと本番で同じコードが動く

マスキング処理は `internal/masking` に閉じており、S3 にも Lambda にも依存しない。
Lambda ハンドラはそこへ設定を渡すだけなので、CLI で確認した挙動がそのまま本番の挙動になる。

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

## 実装状況・未実装

要件と実装・テストの対応は[設計書 §15.1](docs/image-blur-lambda-design.md) に一覧がある。

### 未実装 / 既知の制限

- **対応形式は JPEG / PNG のみ。** Go 標準ライブラリに WebP エンコーダがないため、
  WebP は検証エラーとして DLQ に送られる。対応するなら `golang.org/x/image/webp`
  （デコードのみ）+ 別形式での出力か、cgo を伴うエンコーダの導入が必要。
- **`MAX_ALLOWED_LAPLACIAN_VAR` は暫定値（5.0）。** 実データ 1,000 枚程度で
  分布を取ってから決めること。厳しすぎると正常画像が DLQ に落ちる。
- **アニメーション画像**（GIF / APNG / animated WebP）は非対応。
- CloudTrail のログバケットに Object Lock を設定していない（設計書 §11.3）。
- **`sam validate` / `sam deploy` は未実行。** `template.yaml` はデプロイ検証をしていない。
- **DLQ 再処理スクリプトは未実装。** 手順は[設計書 §13.1](docs/image-blur-lambda-design.md) に記載。
- 実環境での処理時間・スロットリングは未計測（ローカル実測のみ）。

### ローカルで確認できないこと

`cmd/maskfile` で確認できるのは画像処理の部分だけ。以下は dev 環境へのデプロイが必要。

| 項目 | 確認方法 |
|---|---|
| S3 イベントの発火・プレフィックスフィルタ | dev 環境へデプロイして実際に PUT |
| IAM 最小権限（出力バケットを読めないこと等） | dev 環境で当該操作が拒否されることを確認 |
| リトライと DLQ | dev 環境で意図的に失敗させる |
| KMS の暗号化・復号、CloudTrail への記録 | dev 環境で PUT / GET |
| アラームの発火 | 意図的に失敗させる |
| 冪等性・fail-closed・領域・メタデータ除去 | ユニットテストで代替済み |

一覧は[設計書 §14.2](docs/image-blur-lambda-design.md)。
