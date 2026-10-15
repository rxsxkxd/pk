# CD を Lambda の zip と Web のファイルの更新だけにする構成案

> **状態**: 構成案（未実装。2026-10-15）。今の CD（[CI.md](CI.md) 4章の `deploy.yml`、[CD_CI.md](CD_CI.md) の CodePipeline / CodeBuild の案）は、デプロイのたびに CloudFormation のスタックの作成・更新と、ファイルの更新をまとめて行う。この文書は、それを **構築（CloudFormation）と更新（CD）に分ける** 別のパターン。今の CI.md・CD_CI.md・`deploy.yml` は変えていない。採るときに、それぞれをこの案に合わせて直す。

## 1. 考え方

| | 構築 | 更新（CD） |
|---|---|---|
| 中身 | AWS の資源を作る・構成を変える（CloudFormation のスタック、Parameter Store、IAM など） | 動かすもの（Lambda の zip、SPA のファイル）だけを差し替える |
| 頻度 | 初回と、構成を変えるときだけ | コードを変えるたび |
| 誰が・どこで | 運用の担当者が手順書（[DEPLOY.md](DEPLOY.md)・[go/DEPLOY.md](go/DEPLOY.md)・[web/DEPLOY.md](web/DEPLOY.md)）で行う。または構築用の別のパイプライン（7章） | CD（GitHub Actions、または CodePipeline / CodeBuild） |
| 必要な権限 | 広い（CloudFormation、IAM のロールの作成、CloudFront など） | 小さい（4章） |

ねらい:

- CD の権限を小さくする。CD の認証情報が漏れても、資源の作成・削除や IAM の変更はできない
- コードの更新を速く・単純にする（スタックの更新や CloudFront の反映を待たない）
- 構成の変更（CSP、上限、ネットワークなど）を、コードの更新とは別に、確認してから反映する

## 2. 役割分担

| 対象 | 構築 | 更新（CD） |
|---|---|---|
| 成果物バケット | ○（DEPLOY.md 2章） | - |
| Parameter Store の値（salt、コードの固定文字列、解析サーバーの API キー） | ○ | - |
| ネットワークのスタック（`tickets-network-*.yaml`） | ○ | - |
| API のスタック（`api.yaml`）: Lambda の関数と設定（環境変数、メモリ、VPC、予約した同時実行数）、API Gateway（ルート、上限） | ○ | - |
| Lambda のコード（`ticketqr.zip`。`tickets` と `get-qr` は同じ zip） | 初回だけ（スタックの作成に zip が要る。3.1） | ○ |
| Web のスタック（`web.yaml`）: S3、CloudFront、ヘッダー（CSP など） | ○ | - |
| SPA のファイル（`web/dist` の `index.html` と `assets/*`） | 初回は CD を流す | ○ |
| `config.json`（環境ごとの設定: `apiBaseUrl`、`maxImageBytes`） | ○（環境の設定なので構築に含める） | - |
| 発行の上限のスタック（`quota-guard.yaml`） | ○ | - |
| 統合の構成の `PublicBaseUrl`（API のスタックの 2 回目の更新） | ○ | - |
| CORS（直接の構成だけ） | ○ | - |
| CD 用の IAM ロール、OIDC プロバイダー（またはパイプライン） | ○ | - |

迷ったときの決め方: **CloudFormation のテンプレートか、環境の設定が変わるなら構築**。ソースコード（`go/`・`node/`・`web/src/`）だけが変わるなら更新。

## 3. Lambda の zip の扱い（スタックとのずれを防ぐ）

CD が `aws lambda update-function-code` でコードを差し替えると、スタック（`api.yaml` の `Code` の `S3Key`）が指す zip と、実際に動いているコードがずれる。今のままだと、構築でスタックを更新したときに `ArtifactPrefix` が古い場所を指していれば、**古いコードに戻る**。

### 3.1 案: スタックは固定の場所を指し、CD はそこに上げてから差し替える（推奨）

- 構築: API のスタックの `ArtifactPrefix` を、固定の `ticketqr/{impl}/current` にする（`api.yaml` は変えなくてよい。パラメータの値を決めるだけ）。初回の作成の前に、その場所に zip を置いておく
- 更新（CD）: zip を、記録用の `ticketqr/{impl}/releases/{SHA}/ticketqr.zip`（ロールバック用に残す）と、`ticketqr/{impl}/current/ticketqr.zip` の 2 か所に上げ、`update-function-code` で 2 つの関数に反映する
- スタックの `S3Key` は変わらないので、構築でスタックを更新しても、CloudFormation はコードを差し替えない（今動いているコードのまま）。`current` には常に最新の zip があるので、スタックを作り直したときも最新のコードになる

### 3.2 ほかの案

| 案 | 内容 | 採らない理由 |
|---|---|---|
| 構築のときに、最新のリリースの場所を渡す決まりにする | 構築の担当者が、`ArtifactPrefix` に最新の `releases/{SHA}` を指定する | 指定を誤ると古いコードに戻る。人の注意に頼る |
| 構築の後に、必ず CD を流し直す | 戻ったコードを、CD で最新に戻す | 戻ってから直るまでの間、古いコードが動く |
| Lambda のバージョンとエイリアスを使う | CD が `publish-version` してエイリアスを付け替え、API Gateway はエイリアスを呼ぶ | 即時のロールバックができる利点はあるが、`api.yaml` の統合と呼び出し権限をエイリアス向けに直す必要がある。必要になったら検討する |

## 4. 更新（CD）の流れ

```sh
# 入力: CI の成果物（ticketqr.zip、web/dist）。値は構築のスタックの出力から取る
FUNCS="ticketqr-$IMPL-tickets ticketqr-$IMPL-get-qr"

# Lambda: 記録用と current に上げ、2 つの関数に反映して、反映が終わるのを待つ
aws s3 cp ticketqr.zip "s3://$ARTIFACT_BUCKET/ticketqr/$IMPL/releases/$SHA/ticketqr.zip"
aws s3 cp ticketqr.zip "s3://$ARTIFACT_BUCKET/ticketqr/$IMPL/current/ticketqr.zip"
for f in $FUNCS; do
  aws lambda update-function-code --function-name "$f" \
    --s3-bucket "$ARTIFACT_BUCKET" --s3-key "ticketqr/$IMPL/current/ticketqr.zip"
  aws lambda wait function-updated --function-name "$f"
done

# SPA: assets/* を上げてから index.html（古い index.html が新しい assets を指すことはない順番）。config.json は触らない
aws s3 sync web/dist/ "s3://$WEB_BUCKET/" --delete --exclude index.html --exclude config.json \
  --cache-control 'public, max-age=31536000, immutable'
aws s3 cp web/dist/index.html "s3://$WEB_BUCKET/index.html" \
  --cache-control no-cache --content-type 'text/html; charset=utf-8'
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths /index.html

# スモークテスト（今の deploy.yml と同じ。将来は aws-test/PLAN.md の A・B）
```

- 中身は、今の手順書の「コードの更新」（go/DEPLOY.md 4-B.2）と、web/DEPLOY.md 6章のアップロードから `config.json` を除いたもの
- `--delete` は、前の版の `assets/*` を消す。消した直後に古い `index.html` を開いていた利用者が、古い `assets/*` を読めなくなることがある（今の手順と同じ）。気になるなら、`--delete` を外して古いファイルを残し、ときどき片付ける
- 関数の名前（`ticketqr-$IMPL-*`）は `api.yaml` で決まっている。SAM で作った環境では、名前の先頭が `NamePrefix`（既定はスタック名）になる（infra/sam/README.md 3章）

### 4.1 CD に必要な権限

| 対象 | 権限 |
|---|---|
| 成果物バケット | `s3:PutObject`（`ticketqr/{impl}/releases/*` と `ticketqr/{impl}/current/*`） |
| Lambda | `lambda:UpdateFunctionCode`、`lambda:GetFunctionConfiguration`（反映を待つため）。関数 `ticketqr-{impl}-tickets`・`ticketqr-{impl}-get-qr` に限る。`update-function-code` が S3 から zip を読むので、成果物の `s3:GetObject` も要る |
| Web のバケット | `s3:ListBucket`、`s3:PutObject`、`s3:DeleteObject` |
| CloudFront | `cloudfront:CreateInvalidation`（そのディストリビューションに限る） |
| CloudFormation（任意） | `cloudformation:DescribeStacks`（バケット名などをスタックの出力から取る場合。値を CD の変数に持たせるなら要らない） |

今の CD のロール（CI.md 4.2）にある `cloudformation:*`、IAM のロールの作成、`lambda:*`、`apigateway:*`、CloudFront の作成・更新は要らなくなる。

## 5. ロールバック

- Lambda: 前の版の `releases/{SHA}/ticketqr.zip` を `current` に写し、`update-function-code` で反映する（ビルドし直さなくてよい）
- SPA: 前の版の `web/dist` を同じ手順で上げる。前の版の成果物を残す場所（CI の成果物の保持期間、または成果物バケットに `web/releases/{SHA}/` として残す）を決める
- 構成（スタック）の変更を戻すのは、構築の側で行う（前のテンプレート・パラメータでスタックを更新する）

## 6. 今の構成との比較

| 観点 | 今（毎回スタックも更新） | この案（構築と更新を分ける） |
|---|---|---|
| CD の権限 | 広い（資源の作成・削除、IAM） | 小さい（4.1） |
| 1 回の CD の時間 | スタックの更新と CloudFront の反映を待つ | 数十秒〜数分（関数の反映と無効化だけ） |
| 構成の変更の反映 | コードと一緒に、毎回自動で反映される | 構築の手順で、別に反映する。反映を忘れると、テンプレートと実環境がずれる |
| テンプレートと実環境の一致 | 毎回そろう | 構築の手順を流したときだけそろう。ずれは CloudFormation のドリフトの検出や、aws-test/PLAN.md の B（構成の確認）で見つける |
| 初回の構築 | CD だけでできる | 構築の手順（またはパイプライン）が要る。その後に CD を流す |
| コードと構成を同時に変える変更（例: 新しい環境変数を使うコード） | 1 回の CD で済む | 順番が要る: 先に構築で環境変数を足し、その後に CD でコードを出す。逆だとコードが動かない |

## 7. 構築を自動にするか

この案でも、構築を手順書の手作業に限る必要はない。次のどれかにする。

| 案 | 内容 |
|---|---|
| 手作業（手順書） | 今の各 DEPLOY.md の CloudFormation の手順をそのまま使う。頻度が低いうちはこれで足りる |
| 構築用の別のワークフロー・パイプライン | テンプレート（`infra/`）が変わったときだけ、権限の広いロールで、承認を挟んで流す。CD（更新）のロールとは分ける。CloudFormation の変更セットを作り、中身を見てから実行する |

## 8. CD_CI.md の案との組み合わせ

CD_CI.md の構成パターン（P1・P3 など）は、CD を GitHub Actions から CodePipeline / CodeBuild に移す話で、この案とは別の軸。組み合わせられる。

- CodePipeline のデプロイの段階（CodeBuild の `ticketqr-st-deploy`）のコマンドを、4章のものにする。CodeBuild のロールの権限は 4.1 になる
- 構築は、別のパイプライン（7章）か手作業にする

## 9. 決めること

1. この案を採るか（今の「毎回スタックも更新」のままにするか）
2. 構築を手作業にするか、別のパイプラインにするか（7章）
3. Lambda の zip の場所の決まり（3.1 の `current` と `releases/{SHA}` でよいか）
4. SPA の前の版を、どこにどれだけ残すか（5章）
5. 構成のずれをどう見つけるか（CloudFormation のドリフトの検出、aws-test の B を定期的に流す、など）
