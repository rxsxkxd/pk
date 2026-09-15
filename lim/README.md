# image-mask

S3 に置かれた画像の**上半分にガウスぼかしを適用**して、同じバケットの別階層へ保存する Lambda。

- 言語: Go 1.24 / `provided.al2023` / arm64
- IaC: AWS SAM（`template.yml` + `samconfig.toml`）
| 文書 | 内容 |
|---|---|
| [docs/test-local.md](docs/test-local.md) | **ローカルテスト（Go のみ）**。AWS も Docker も不要 |
| [docs/test-sam-local.md](docs/test-sam-local.md) | **SAM 経由のローカルテスト**。Docker + AWS 認証情報が必要 |
| [docs/deploy.md](docs/deploy.md) | **AWS へのデプロイ** |
| [docs/image-blur-lambda-design.md](docs/image-blur-lambda-design.md) | 設計 |

キーは 7 要素に固定し、**変数だけを呼び出し側から受け取る**。

```
<bucket>/[<prefix>/]<tid>/<infix>/<date>/<lid>/<eid>
           ~~~~~~    ~~~   ~~~~~   ~~~~   ~~~   ~~~
           Lambda    変数  Lambda  変数   変数  変数
           (任意)          (必須)
```

原本とマスク済みは **infix だけが異なる**。

```
原本      : masking/t-001/no-masked/2026-09-14/loc-12/e-98765
                 │  リクエスト（または S3 イベント通知）
                 ▼
            Lambda (image-mask)  ── 失敗 ──▶ CloudWatch アラーム ──▶ メール
                 │
                 ▼
マスク済み: masking/t-001/masked/2026-09-14/loc-12/e-98765
```

`prefix` は任意。指定しなければ `tid` から始まる。

強度に関わる設定を変えたときは `MASKING_POLICY_VERSION` を上げる。出力のメタデータに
入っており、版が変われば過去の出力が作り直される（同じキーを上書き）。

## 構成

| パス | 内容 |
|---|---|
| `cmd/mask` | Lambda エントリポイント |
| `cmd/maskfile` | ローカル実行用 CLI（S3 不要） |
| `cmd/gensample` | 動作確認・性能計測用のサンプル画像を生成 |
| `internal/handler` | S3 イベント処理（検証・冪等性・fail-closed） |
| `internal/masking` | マスキング処理そのもの。Lambda と CLI が共有する |
| `internal/imaging` | ぼかし、領域切り出し、EXIF 向き補正、強度測定 |
| `internal/s3key` | キー構造の組み立てと解釈、変数の検証 |
| `internal/config` | 環境変数の読み込み |
| `internal/metrics` | EMF によるカスタムメトリクス出力 |
| `template.yml` | バケット・KMS・Lambda・SNS・CloudWatch アラーム |
| `samconfig.toml` | スタック名・リージョン・環境ごとのパラメータ |

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

手元に試せる画像がなければ、サンプルを生成できる（実写真は置かない）。

```bash
make sample     # testdata/ に生成
```

| ファイル | 用途 |
|---|---|
| `person.jpg` / `.png` | 全身の人物を引きで捉えた構図。頭部が上半分に収まる |
| `idcard.jpg` | 身分証のレイアウト。**実際の用途に最も近い** |
| `big.jpg` (4000×3000) | 性能計測用 |
| `small.png` (120×90) | 半径が下限 8px に張り付くケース |
| `broken.jpg` | 画像でないファイル（検証エラー確認用） |

実写真は置かない。標準ライブラリだけで描いた合成画像だが、抽象的な模様ではなく
人物・身分証の形にしてあるのは、マスクの効き方が被写体の性質に左右されるため。
撮影ノイズも加えてあり、これがないとスコアが現実より低く出て調整に使えない。

```bash
go run ./cmd/maskfile -out tmp/masked.jpg testdata/idcard.jpg
# または（出力先は既定で tmp/masked.jpg）
make run IN=testdata/idcard.jpg
```

`-out` に `tmp/masked.jpg` のようなパスを渡すと、途中のディレクトリは自動で作られる。
`tmp/` は `.gitignore` 済みなので、確認用の出力はここへ置けばよい。

```
testdata/idcard.jpg  jpeg 1200x900  radius=36px  top 50% (0,0,1200,450)
                     score=2.6749 (limit 15.0, ok)  153KB->95KB  43ms
                     -> tmp/masked.jpg
```

`idcard.jpg` の結果は、顔写真と氏名・番号が判別不能になる一方、署名とバーコードは
鮮明なまま残る。**境界のすぐ下の行が読めるまま残る**のも見て取れるので、
`MASK_HEIGHT_RATIO` の既定 0.5 で足りるかの判断材料になる。

まとめて処理する場合と、しきい値を調整する場合:

```bash
# 複数ファイルを出力ディレクトリへ
go run ./cmd/maskfile -out-dir tmp/out ./samples/*.jpg

# 出力は書かずスコアだけ集める（MAX_ALLOWED_LAPLACIAN_VAR の決定用）
go run ./cmd/maskfile -report-only -json ./samples/*.jpg | jq -s 'map(.strengthScore) | max'

# 領域やぼかしの強さを変えて確認
go run ./cmd/maskfile -mask-height-ratio 0.6 -blur-ratio 0.06 -out tmp/out.jpg photo.jpg
```

強度検証に落ちた場合とデコードに失敗した場合は、本番で失敗になるのと同じ分類が
表示され、終了コードが 1 になる。

```
broken.jpg  FAILED (validation) cannot decode image header: image: unknown format
photo.jpg   FAILED (strength) mask strength check failed: laplacian variance 30.734 > 15.000
```

### 確認すべき 3 点

1. **上半分の内容が判別できないこと** — 隠したい情報が読めないか
2. **下半分が変化していないこと** — にじみ・色ずれがないか
3. **`score` が `limit` に対して十分小さいこと** — どれだけ余裕があるか

### リリース前に必ずやること

`MAX_ALLOWED_LAPLACIAN_VAR = 15.0` は合成画像から置いた暫定値。厳しすぎれば正常画像が
正常な画像まで失敗になる。実データで分布を取ってから決める。なおマスクの強さ自体は
`MIN_BLUR_RATIO` で担保しており、このしきい値はあくまで事故検知用。

```bash
go run ./cmd/maskfile -report-only -json ./samples/*.jpg > tmp/scores.jsonl
jq -s 'map(.strengthScore) | {max: max, p99: (sort | .[(length*0.99|floor)])}' tmp/scores.jsonl
```

詳細は[設計書 §14.1](docs/image-blur-lambda-design.md)。

## テストとデプロイ

```bash
make test              # go test ./... -race
make validate          # sam validate
make deploy            # sam build && sam deploy（dev）
make deploy ENV=prod   # prod へ
```

**手順は [docs/deploy.md](docs/deploy.md) にまとめてある。** 初回デプロイ、デプロイ直後に
必要な作業、動作確認、設定変更、削除、つまずきやすい点まで。

その前段として、[ローカルテスト（Go のみ）](docs/test-local.md) と
[SAM 経由のローカルテスト](docs/test-sam-local.md) を別の文書に分けてある。

### 失敗した入力の扱い

**失敗イベントの退避先（DLQ）は置いていない。** リトライを使い切ったイベントは破棄される。

失敗したことと対象は CloudWatch のログ・メトリクスと、アラームからのメールで分かる。再処理はログの `sourceKey`
から変数を読み取り、リクエスト起動で投げ直す（処理は冪等なので投げ直して害はない）。

```bash
aws lambda invoke --function-name image-mask-dev --payload '{
  "tenant_id": "t-001", "date": "2026-09-14",
  "location_id": "loc-12", "entry_id": "e-98765"
}' out.json
```

ログの保持期間（30 日）を過ぎると、何が失敗したのかを追えなくなる。

### エラー通知（Amazon SNS）

エラーは CloudWatch メトリクスに記録され、CloudWatch アラーム（`AWS::CloudWatch::Alarm`）
経由で SNS からメールに届く。デプロイ時に `AlertEmail` を指定する。

```
処理の失敗 ─▶ CloudWatch メトリクス ─▶ CloudWatch アラーム ─▶ SNS ─▶ メール
```

**デプロイ後、そのアドレスに届く確認メールのリンクを押す必要がある。**
押すまで通知は届かない（CloudFormation では自動承認できない）。しかも未承認でも
スタックの作成は成功するので、忘れると「鳴っているのにメールが来ない」状態になる。

```bash
aws sns list-subscriptions-by-topic --topic-arn "$ALERT_TOPIC_ARN" \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
```

`AlertEmail` を空のままデプロイすることもできる（CloudWatch アラームは動くが通知先がない状態）。

### 起動方法

実装は 2 通りに対応しているが、**既定では S3 イベント通知は無効**で、リクエスト起動だけが有効。

| 起動方法 | 実装 | 既定 |
|---|---|---|
| リクエスト | 対応 | **有効** |
| Amazon S3 イベント通知（`s3:ObjectCreated:*`） | 対応 | 無効（`EnableS3Trigger=true` で有効化） |

**変数を渡して呼ぶ**

```bash
aws lambda invoke --function-name image-mask-dev --payload '{
  "tenant_id": "t-001", "date": "2026-09-14",
  "location_id": "loc-12", "entry_id": "e-98765"
}' out.json
```

```json
{
  "sourceKey": "masking/t-001/no-masked/2026-09-14/loc-12/e-98765",
  "outputKey": "masking/t-001/masked/2026-09-14/loc-12/e-98765",
  "skipped": false, "radiusPx": 36, "strengthScore": 1.15
}
```

処理済みなら `skipped: true`（冪等）。変数にスラッシュや `..` を含めてキーを
別の場所へ向ける細工は検証で弾く。**エラーは呼び出し元に返る。**

同期呼び出し（既定の `RequestResponse`）では Lambda は自動リトライしない。
再試行は呼び出し元の責任になる。

`EnableS3Trigger=true` にすると、原本を置くだけでも処理が走る。

```bash
aws s3 cp id.jpg s3://$BUCKET/masking/t-001/no-masked/2026-09-14/loc-12/e-98765
aws s3 cp s3://$BUCKET/masking/t-001/masked/2026-09-14/loc-12/e-98765 ./masked.jpg
```

## 前提としていること

この実装は以下を**前提**にしている。崩れると設計が成立しない。
全項目と確認状況は[設計書 §3.1](docs/image-blur-lambda-design.md) にある。

- **隠したい情報は常に画像の上半分にある。**
  検出処理を使わないため検出漏れは起こらないが、対象が下半分に写っていた場合は
  **何も検知されずに露出する**。技術的な緩和策はなく、入力側の運用で担保するしかない。
- 入力は JPEG / PNG のみ（WebP は現状、検証エラーになる）。
- 1 枚あたり 20 MB / 8000 × 8000 px 以内。
- ラプラシアン分散 15.0 というしきい値で「設定を桁で外した事故」を拾える（**未検証**）。
- EXIF Orientation の有無は**未確認**。付いている場合、向きの判定を誤ると
  「違う半分をマスクする」事故になりうる。実データを確認するまで保留としている
  （[設計書 §3.1](docs/image-blur-lambda-design.md) の A9）。

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

大きな半径でも速度が落ちないよう、ぼかしはボックスぼかしの重ね掛けで
ガウス分布を近似している（半径によらず O(pixels)）。8bit のまま窓を 1 画素ずつ
滑らせて加減算するため、float への展開もメモリ帯域も要らない。

4000×3000 の処理は end-to-end で **268ms**（うちぼかし 86ms）。残りの 179ms は
JPEG のデコードとエンコードで、これは JPEG を扱う以上削れない。
最適化の内訳と、測ったうえで棄却した案は[設計書 §13.4](docs/image-blur-lambda-design.md)。

重ねる回数は `BLUR_PASSES` で決まる。マスキングに必要なのは「情報を落とすこと」で
あって滑らかさではないため、**既定は 2 回**（3 回から end-to-end 約 12% 短縮）。
4000×3000 の JPEG で 303ms → 268ms、マスク強度は変わらない（スコア 0.049 で一致）。

1 回は許可していない。矩形窓の周波数応答は sinc 状で副ローブを持つため、
特定の空間周波数の成分が残る。2 回重ねれば副ローブが二乗されて十分小さくなる。

### マスク領域の外には一切手を加えない

縮小・拡大を含むすべての処理は切り出した矩形の中だけで行い、画像全体の縮小はしない。
非マスク領域は再エンコードを除いて画素単位で不変で、テストで固定している。

### 出力前に強度を自己検証する（fail-closed）

マスク**領域だけ**を 64px の区画に割り、**最もエッジが残った区画**のラプラシアン分散が
`MAX_ALLOWED_LAPLACIAN_VAR` を超えたら `PutObject` を行わずにエラーを返す。

2 点が要点。

- **画像全体ではなく領域だけを測る。** 全体で測ると、鮮明なままの下半分に引きずられて
  正常な入力まで失敗になる
- **領域の平均ではなく区画の最悪値を見る。** 平均だと小さな素通し部分が広い平坦な背景に
  薄められる。引きの人物写真では顔が領域の 0.87% しかなく、顔が読める状態でも
  平均は 1.43（合格）だった。区画判定なら 30.7 で不合格になる

ただしこの検査で捕まえられるのは**大きく外した事故**で、軽度のぼかし不足は検知できない。
`MAX_ALLOWED_LAPLACIAN_VAR = 15.0` はそのばらつきの上に置いた値。リリース前に
実データで取り直すこと。

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
| `OUTPUT_BUCKET` | = `INPUT_BUCKET` | 出力先。既定は同じバケット |
| `INPUT_BUCKET` | （必須） | 原本のあるバケット |
| `KEY_PREFIX` | （空） | 共有バケット内のルート。任意 |
| `ORIGINAL_INFIX` | `no-masked` | 原本の階層 |
| `MASKED_INFIX` | `masked` | マスク済みの階層 |
| `MASKING_POLICY_VERSION` | `v1` | 強度設定のラベル。メタデータに記録され、上げると過去分が作り直される |
| `MASK_HEIGHT_RATIO` | `0.5` | 上部からマスクする高さの比率 |
| `MIN_BLUR_RATIO` | `0.04` | 短辺に対するぼかし半径の比率 |
| `MIN_BLUR_RADIUS_PX` | `8` | 半径の絶対下限 |
| `BLUR_PASSES` | `2` | ボックスぼかしの重ね回数。2 未満は不可 |
| `DOWNSCALE_FACTOR` | `4` | マスク領域の縮小率（1 で無効） |
| `STRENGTH_BLOCK_PX` | `64` | 強度検証の区画サイズ |
| `MAX_ALLOWED_LAPLACIAN_VAR` | `15.0` | 強度検証のしきい値 |
| `MAX_INPUT_BYTES` | `20971520` | 入力サイズ上限 |
| `MAX_INPUT_PIXELS` | `64000000` | 総ピクセル数上限 |
| `JPEG_QUALITY` | `85` | JPEG 出力品質 |
| `LOG_LEVEL` | `INFO` | ログレベル |

## 要件外の追加について

依頼になかったが設計側の判断で入れた構成（KMS カスタマー管理キー、バージョニングなど）は、
理由と外した場合の影響を
[設計書 §15.4](docs/image-blur-lambda-design.md) に一覧してある。
いずれも `template.yml` から削るだけで外せる（コード変更は不要）。

## 実装状況・未実装

要件と実装・テストの対応は[設計書 §15.1](docs/image-blur-lambda-design.md) に一覧がある。

### 未実装 / 既知の制限

- **対応形式は JPEG / PNG のみ。** WebP は今回考慮外で、検証エラーになる
  （Go 標準ライブラリに WebP エンコーダがないため、対応するなら別形式での出力か
  cgo を伴うエンコーダの導入が要る）。
- **`MAX_ALLOWED_LAPLACIAN_VAR` は暫定値（15.0）。** 実データ 1,000 枚程度で
  分布を取ってから決めること。厳しすぎると正常な画像まで失敗になる。
- **許容ライン `MIN_BLUR_RATIO >= 0.004` は合成画像 1 枚に対する目視判断。**
  被写体がさらに小さい写真では不十分な可能性がある（既定はその 10 倍の 0.04）。
- **アニメーション画像**（GIF / APNG / animated WebP）は非対応。
- **`sam deploy` は未実行。** `sam validate --lint` と `sam build` は通過しているが、
  実際に AWS へ反映した確認はしていない。
- 実環境での処理時間・スロットリングは未計測（ローカル実測のみ）。

### ローカルで確認できないこと

`cmd/maskfile` で確認できるのは画像処理の部分だけ。以下は dev 環境へのデプロイが必要。

| 項目 | 確認方法 |
|---|---|
| S3 イベントの発火・プレフィックスフィルタ | dev 環境へデプロイして実際に PUT |
| IAM 最小権限（出力バケットを読めないこと等） | dev 環境で当該操作が拒否されることを確認 |
| リトライと CloudWatch アラームの発火 | dev 環境で意図的に失敗させる |
| KMS の暗号化・復号 | dev 環境で PUT / GET |
| CloudWatch アラームの発火 | 意図的に失敗させる |
| 冪等性・fail-closed・領域・メタデータ除去 | ユニットテストで代替済み |

一覧は[設計書 §14.2](docs/image-blur-lambda-design.md)。
