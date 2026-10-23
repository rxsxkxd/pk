# 全体でのアクセス数の制限: WAF と API Gateway の比較

> **2026-10-14 の決定**: 経路は統合（すべて CloudFront で受ける）。アクセス数の制限は API Gateway と WAF の両方に入れる予定で、**API Gateway 側は「1時間 1 万件・1日 10 万件」で確定し、実装した（7章）**。WAF は判断を後回し。
>
> 2026-10-14 作成。送信元ごとではなく、**API 全体**でアクセス数（リクエストの数）を制限する場合に、WAF と API Gateway のどちらで行うかの比較。仕様は AWS の公式の文書（下の「参考」）で確かめた。実装・AWS 上での確認はしていない。

## 1. 結論

- **API Gateway のスロットリングを主にする**（今もある。既定の構成（直結）でそのまま効き、追加の費用もない）。全体の上限は、画像解析サーバーが受けられる量に合わせて決める
- **WAF は、統合の構成（CloudFront の `/v1/*` から API）を使う場合に、送信元ごと（IP ごと）の制限を足すのに向く**。全体の制限も書けるが、数え方が粗く（数十秒の遅れ）、全体の上限を正確に守る用途には向かない
- どちらの「全体の制限」も、上限に達すると**正しい利用者もまとめて断られる**。1人が大量に送ると、ほかの全員が使えなくなる（送信元ごとの制限と組み合わせて和らげる）

## 2. 今の設定

| 場所 | 設定 | 値 |
|---|---|---|
| API Gateway（`api.yaml`・SAM の `DefaultStage`） | ステージの既定のスロットリング（`DefaultRouteSettings`。各ルートに同じ値が効く） | 1 秒あたり 50（`ThrottlingRateLimit`）、一時的に 100（`ThrottlingBurstLimit`） |
| API Gateway（`example.yaml`） | 同上 | 10 / 20 |
| AWS アカウント | リージョンごとの、すべての API の合計の上限（AWS の既定。申請で上げられる） | AWS の割り当て（Service Quotas）の値 |
| Lambda（`tickets`） | 予約同時実行数（`GrantReservedConcurrency`。画像解析サーバーを守る） | 既定は設定しない（-1） |
| WAF | なし（Web ACL はテンプレートに含めていない。案は web/DEPLOY.md 13章。送信元ごとの制限） | - |

## 3. 比較

| 観点 | API Gateway のスロットリング | WAF のレート制限（集計を「すべて」にする） |
|---|---|---|
| 使える構成 | **直結・統合のどちらでも**（API Gateway に付く） | **統合の構成だけ**（HTTP API には WAF を直接付けられない。CloudFront に付ける） |
| 数え方 | トークンバケット（1 秒あたりの量と、一時的に許す量）。ほぼすぐに効く | 決めた時間枠（1・2・5・10 分）の中の数を、こまめに見積もる。**越えてから止めるまで、ふつうは 30 秒以内の遅れ（最大で数分）**。止めるのをやめるときも同じ |
| 正確さ | 「目安」（ベストエフォート）。一時的に越えることがある | 「上限の近く」で止める。正確な上限は保証しない（AWS の文書に明記） |
| 対象を絞る | ルートごとに値を変えられる（例: 発行の `POST /v1/tickets` だけ厳しく） | 条件で絞れる（パス・メソッド・ヘッダーなど。全体の集計では、絞る条件の指定が必須） |
| 送信元ごとの制限 | **できない**（HTTP API には利用量プランも API キーもない） | **できる**（IP ごと、ヘッダーの値ごとなど）。全体の制限と組み合わせられる |
| 止めたときの応答 | 429（`{"message":"Too Many Requests"}`） | 403（CloudFront の HTML）。応答のステータスや本文は変えられる（例: 429 にする） |
| Lambda・解析サーバーへの影響 | 止めたリクエストは Lambda を呼ばない | 止めたリクエストは API Gateway にも届かない |
| 迂回 | できない（API Gateway そのものに付く） | **execute-api の URL を直接呼ぶと迂回できる**（web/DEPLOY.md 11章。防ぐには追加の作業） |
| 費用 | 追加の費用なし | Web ACL 月 5 USD、ルール 1 つ月 1 USD、リクエスト 100 万件あたり 0.60 USD（目安。公式の料金で確かめる） |
| 設定の変更 | テンプレートのパラメータ（`ThrottlingRateLimit`・`ThrottlingBurstLimit`）を変えてデプロイ。数分で反映 | Web ACL を更新。変えると、そのルールの数がリセットされ、最大 1 分ほど制限が止まる |
| 見える化 | アクセスログの `status`（429）、CloudWatch のメトリクス | WAF のログ（どのルールで止めたか）、サンプル、メトリクス。**数えるだけ（Count）で試せる** |
| 対象の範囲 | API だけ | 統合の構成では、画面（S3）も含めて同じ Web ACL で守れる |

## 4. pros / cons

### 4.1 API Gateway のスロットリング

pros:

- 既定の構成（直結）でそのまま使え、今も設定済み。追加の費用もない
- ほぼすぐに効く（WAF より細かく、短い山も抑えられる）
- ルートごとに値を変えられ、発行（画像解析を呼ぶ）だけを厳しくできる
- 迂回できない

cons:

- 送信元ごとの制限ができない。1人の大量のリクエストで上限に達すると、全員が断られる
- 応答（429）の本文が API の JSON の形ではないので、今の SPA は「発行できませんでした。もう一度お試しください」と出す（「混み合っています」と出すには、SPA で 429 を読み分ける変更が要る）
- アカウント全体の上限（同じリージョンのほかの API と共有）にも影響される

### 4.2 WAF のレート制限（全体）

pros:

- 送信元ごとの制限と、全体の制限を、1 つの Web ACL でまとめて持てる
- 止めたリクエストは API Gateway・Lambda に届かないので、その分の費用もかからない
- 数えるだけ（Count）で、実際の量を見てから止める設定にできる。止めた理由がログで分かる
- 応答のステータスや本文を変えられる

cons:

- **既定の構成（直結）では使えない**。統合の構成（CloudFront の `/v1/*`）が前提
- 数え方が粗い（数十秒の遅れ）。短い山は止められず、全体の上限を正確に守る用途には向かない
- execute-api を直接呼ばれると迂回される
- 費用がかかる（月 数 USD ＋ リクエストごと）
- 止めたときの応答（403 の HTML）を、今の SPA は「発行できませんでした」としか出せない

## 5. 推奨の組み合わせ

| 目的 | どこで | 値の決め方 |
|---|---|---|
| API 全体（特に画像解析サーバー）を守る | **API Gateway のスロットリング**（発行のルートだけ、ほかより厳しくする） | 画像解析サーバーが受けられる量（1 秒あたり）から決める。想定の発行量（ピーク 1 秒 2 件）より十分大きく |
| 解析サーバーへの同時の呼び出しを抑える | Lambda の予約同時実行数（`GrantReservedConcurrency`） | 解析サーバーの同時に受けられる数から決める |
| 1 人（1 つの IP）からの大量のアクセスを止める | WAF の送信元ごとの制限（統合の構成のとき） | web/DEPLOY.md 13章の案（5 分 100 回。携帯回線の共有 IP に注意） |

## 7. 実装した上限（1時間 1 万件・1日 10 万件）

API Gateway（HTTP API）には、1時間・1日あたりの上限の設定がない（設定できるのは 1 秒あたりの量と、一時的に受けられる量だけ）。そこで、数えて止める仕組みを別のスタック（`infra/cloudformation/quota-guard.yaml`）で作った。

```
tickets 関数の呼び出し回数（CloudWatch の AWS/Lambda Invocations）
  ├─ 1時間の合計 ≥ 10,000 → アラーム（…-hourly）
  └─ 1日の合計 ≥ 100,000 → アラーム（…-daily）
        │ どちらかが ALARM になったとき・両方が OK に戻ったとき（と、10 分ごと）
        ▼
  ガードの関数（Python。テンプレートの中に書いてある）
    どちらかが ALARM → 発行のルート（POST /v1/tickets・POST /v1/tickets/qr-inline）のスロットリングを 0（すべて 429）
    両方が OK        → 元の値（1 秒 50・一時的に 100）に戻す
```

| 項目 | 内容 |
|---|---|
| 数えるもの | `tickets` 関数（発行の Lambda）の呼び出し回数。止めている間に断ったリクエスト（429）は Lambda を呼ばないので数えない（API Gateway の `Count` は 429 も数えるので使わない。数え続けて戻らなくなるため） |
| 止めるもの | 発行のルートだけ。QR 画像とチケットの画面（`GET`）は止めないので、発行済みのチケットは表示できる |
| 止めている間 | 発行は 429 になる（画面は「発行できませんでした。もう一度お試しください」。「混み合っています」にするには SPA の変更が要る） |
| 戻るとき | 次の時間の枠（1時間・1日）で合計が上限を下回り、アラームが OK に戻ったとき |
| 遅れ | Lambda のメトリクスとアラームの評価に数分かかる。そのあいだは上限を少し超えることがある |
| 予備 | 10 分ごとにも状態をかけ直す（アラームの動作が届かなかったときや、API のスタックを更新してルートの設定が変わったときのため） |
| 費用（目安） | アラーム 2 つ（月 0.2 USD 程度）、ガードの関数の実行（ほぼ 0） |

デプロイ（API のスタックのあとに。実装ごとに 1 つ）:

```sh
export API_ID=$(aws cloudformation describe-stacks --stack-name ticketqr-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='ApiId'].OutputValue" --output text)
aws cloudformation deploy \
  --stack-name ticketqr-quota-$IMPL \
  --template-file infra/cloudformation/quota-guard.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides ApiId=$API_ID TicketsFunctionName=ticketqr-$IMPL-tickets
```

- 上限を変えるときは `HourlyLimit`・`DailyLimit` を変える。API のスタックの `ThrottlingRateLimit`・`ThrottlingBurstLimit` を変えたときは、このスタックの `RateLimit`・`BurstLimit` も同じ値にする（止めたあとに戻す値）
- SAM で作った API（`ticketqr-sam-$IMPL`）にも、同じように `ApiId` を渡して付けられる
- デプロイのワークフロー（`cd/github-actions/deploy.yml`。採用していない旧案）にも、API のスタックのあとに足した

確かめたこと（2026-10-14）: cfn-lint、ガードの関数の動き（AWS の部分を差し替えて、アラームの状態の組み合わせごとに、止める・戻すが正しいこと）。

AWS 上で確かめること:

1. ルートのスロットリングを 0 にすると、そのルートがすべて 429 になること（公式の文書には直接の記述がない。利用者の報告では 429 になる）
2. 1時間・1日の枠の区切り方（毎正時で区切るか。1日は UTC 0 時 = 日本時間 9 時で区切られるか）。区切りによって、戻る時刻が変わる
3. 止めてから戻るまでの実際の時間と、上限を超える量
4. アラームから関数を直接動かせること（`lambda.alarms.cloudwatch.amazonaws.com` の許可）

注意:

- 数えるのは `tickets` 関数の呼び出しなので、発行のほかに、フォーム送信方式のチケット表示（`GET /v1/tickets/{code}/view`。同じ関数）も数える。画面遷移方式（本番の方式）では使わない
- 上限に達すると、全員の発行が止まる（1 人の大量の発行でも止まる）。送信元ごとの制限は WAF（後回し）で行う

## 6. 参考

- [Throttle requests to your HTTP APIs - Amazon API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-throttling.html)
- [Rate-based rule high-level settings in AWS WAF](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based-high-level-settings.html)
- [Rate-based rule caveats in AWS WAF](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based-caveats.html)
- [AWS WAF Pricing](https://aws.amazon.com/waf/pricing/)
