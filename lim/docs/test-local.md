# ローカルテスト（Go のみ）

AWS も Docker も使わずに、**画像処理そのもの**を確認する手順。

| 確認できること | ユニットテスト、画像処理の目視確認、しきい値の調整、性能計測 |
|---|---|
| **確認できないこと** | S3 との連携、IAM、イベントの配線（→ [test-sam-local.md](test-sam-local.md) / [deploy.md](deploy.md)） |

必要なのは **Go 1.24 以降だけ**。

---

## 1. ユニットテスト

```bash
make test        # go test ./... -race -count=1
go vet ./...
```

画像処理・ハンドラ・冪等性・fail-closed・キー構造の検証まで含む。テスト用の画像は
すべてテストコード内でメモリ上に生成しており、ファイルは読まない。

## 2. サンプル画像を用意する

```bash
make sample      # testdata/ に生成
```

| ファイル | 用途 |
|---|---|
| `person.jpg` / `.png` | 全身の人物（引き）。頭部が上半分に収まる |
| `idcard.jpg` | 身分証のレイアウト。**実際の用途に最も近い** |
| `big.jpg` (4000×3000) | 性能計測用 |
| `small.png` (120×90) | 半径が下限 8px に張り付くケース |
| `broken.jpg` | 画像でないファイル（検証エラー確認用） |

実写真はリポジトリに置かない。合成画像だが、撮影ノイズを加えてあるためスコアの傾向は
実データに近い。

## 3. 画像を 1 枚処理して目で見る

```bash
go run ./cmd/maskfile -out tmp/masked.jpg testdata/idcard.jpg
# make run IN=testdata/idcard.jpg でも同じ（出力は tmp/masked.jpg）
```

```
testdata/idcard.jpg  jpeg 1200x900  radius=36px  top 50% (0,0,1200,450)
                     score=2.6749 (limit 15.0, ok)  153KB->95KB  43ms
                     -> tmp/masked.jpg
```

確認すべき点は 3 つ。

1. **上半分の内容が判別できないこと**
2. **下半分が変化していないこと**（にじみ・色ずれがないか）
3. **`score` が `limit` に対して十分小さいこと**

`tmp/` は `.gitignore` 済み。

## 4. パラメータを変えて比較する

```bash
for r in 0.4 0.5 0.6 0.7; do
  go run ./cmd/maskfile -mask-height-ratio $r -out "tmp/h$r.jpg" testdata/idcard.jpg
done
```

弱い設定は強度検査に落ちて出力されない。観測目的なら検査を無効にする。

```bash
go run ./cmd/maskfile -blur-ratio 0.002 -min-blur-radius-px 0.1 \
  -max-laplacian-var 1e9 -out tmp/weak.jpg testdata/person.jpg
```

## 5. しきい値のキャリブレーション（リリース前に必須）

`MAX_ALLOWED_LAPLACIAN_VAR = 15.0` は合成画像から置いた暫定値。実データで取り直す。

```bash
go run ./cmd/maskfile -report-only -json ./samples/*.jpg > tmp/scores.jsonl
jq -s 'map(.strengthScore) | {max: max, p99: (sort | .[(length*0.99|floor)])}' tmp/scores.jsonl
```

最大値に余裕を持たせた値を設定する。詳細は[設計書 §12.4](image-blur-lambda-design.md)。

## 6. 異常系

```bash
go run ./cmd/maskfile -out tmp/x.jpg testdata/broken.jpg; echo "exit=$?"
```

本番で失敗するのと同じ分類が出て、終了コードが 1 になる。

```
broken.jpg  FAILED (validation) cannot decode image header: image: unknown format
```

---

## 次の段階

- S3 との連携やイベントの形を確認する → [test-sam-local.md](test-sam-local.md)
- AWS へ反映する → [deploy.md](deploy.md)
