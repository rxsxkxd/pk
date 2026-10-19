# 発行画面（画像アップロード画面）のエラー文言と、表示位置の変え方

> 2026-10-13 時点の実装（`sh` ブランチ）。対象は SPA の発行画面（画面遷移方式・その場表示方式。`src/modes/{page,inline}/GrantPage.vue`）。文言の正式な対応表は ../DESIGN.md 4.4、画面の要素は ../SCREENS.md。

## 1. エラー文言の一覧

### 1.1 送る前の確認（選んだ画像の問題）

`src/stores/ticket.ts` の `checkFile`。画像を選んだとき（上限を超えていれば、縮めたあと）に確かめ、問題がある間は「発行する」を押せない。

| 条件 | 文言 | 表示 |
|---|---|---|
| 画像を選んでいない | 証明書の画像を選んでください | **出さない**（ボタンが押せないことで分かる） |
| 上限（`config.json` の `maxImageBytes`。既定 4MB）を超え、縮めても収まらない・縮められない（デコードできない HEIC など） | 画像のサイズが大きすぎます（4MB まで） | エラーの枠。「4MB」は `maxImageBytes` から作る（`sizeLabel`） |
| 対応していない形式（MIME タイプも拡張子も、JPEG / PNG / HEIC / HEIF / AVIF / WebP でない） | この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP） | エラーの枠 |

### 1.2 送ったあとの API の結果

`src/stores/ticket.ts` の `messageFor`。API のエラーコード（`src/api/client.ts` の `ApiError`）を文言にする。送るたびに消え、別の画像を選んでも消える。もう一度押して送り直せる。

| エラーコード | 起きるとき | 文言 |
|---|---|---|
| `PAYLOAD_TOO_LARGE`（413） | API の上限を超えた（SPA と API の上限の設定がずれているとき） | 画像のサイズが大きすぎます（数字は出さない。API の上限は SPA からは分からないため） |
| `UNSUPPORTED_MEDIA_TYPE`（415） | API が画像として読めなかった | この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP） |
| `IMAGE_REJECTED`（422） | 解析サーバーの判定が REJECT | この証明書の画像ではチケットを発行できません |
| `IMAGE_RETRY`（422） | 解析サーバーの判定が RETRY | 画像をうまく確認できませんでした。明るい場所で、証明書全体が写るように撮り直してください |
| `ANALYSIS_UPSTREAM_ERROR`（502）・`ANALYSIS_TIMEOUT`（504） | 解析サーバーにつながらない・時間切れ | ただいま混み合っています。時間をおいてお試しください |
| それ以外（`BAD_REQUEST` 400、`NETWORK` 通信の失敗・30 秒のタイムアウト、`UNEXPECTED` 想定外の応答、API Gateway・CloudFront のエラー） | - | 発行できませんでした。もう一度お試しください |

### 1.3 そのほか（発行画面の外）

| 場面 | 文言 | 場所 |
|---|---|---|
| 起動時に `config.json` を読めない・形が違う | 設定を読み込めませんでした。時間をおいて再読み込みしてください。 | 画面全体をこの1文に置き換える（`src/main.ts`） |
| チケット画面の URL が正しくない・QR を読み込めない | 無効なチケット URL です | チケット画面の QR の場所（`src/modes/page/TicketPage.vue`） |
| フォーム送信方式で、API がエラーを返した | 見出し「チケットを表示できません」と、API のエラーの説明（英語。例: `image was rejected`） | API のエラーページ（SPA の外。`go/internal/view/templates/error.html`） |

- フォーム送信方式のエラーページの説明は、API の英語の `message` をそのまま出している。日本語にするなら、API 側の変更になる

## 2. 今の表示の仕組み

```
src/stores/ticket.ts
  fileProblem   = 送る前の確認の結果（checkFile）
  error         = API の結果の文言（messageFor）。送るたび・別の画像を選ぶと消える
  errorMessage  = 画像を選んでいれば fileProblem、なければ error（1 か所に出す文言）
        │
        ▼
src/modes/page/GrantPage.vue・src/modes/inline/GrantPage.vue
  …「発行する」ボタン
  <ErrorMessage v-if="store.errorMessage" :message="store.errorMessage" />   ← ボタンの下
        │
        ▼
src/components/ErrorMessage.vue
  <p role="alert" class="… bg-red-50 … text-red-800" data-testid="error">{{ message }}</p>
```

- 「どの文言を出すか」はストア（`errorMessage`）、「どこに出すか」は各方式の `GrantPage.vue`、「どう見せるか」は `ErrorMessage.vue` が決める
- 表示位置の指定は、2つの `GrantPage.vue`（画面遷移方式・その場表示方式）に同じ1行がある

## 3. 表示位置を変えたいときの直し方

### 3.1 枠ごと別の場所に動かす（例: ボタンの上、画像の選択の下）

1. `src/modes/page/GrantPage.vue` と `src/modes/inline/GrantPage.vue` の `<ErrorMessage v-if="store.errorMessage" … />` の行を、テンプレートの中で動かす（2 ファイルとも）
2. テストの並びの確認を直す（`src/modes/page/page.test.ts` の「ボタンの後に `error` がある」確認）
3. ../SCREENS.md（Android 版・iOS 版の表の順番）と ../DESIGN.md 3章の画面の図を直す

ストアと `ErrorMessage.vue` は変えなくてよい。

### 3.2 送る前の問題と API のエラーを、別々の場所に出す（2026-10-13 より前の形）

1. 送る前の問題（`store.fileProblem`）を、画像の選択の近くに出す。例: `CertificateImagePicker.vue` に `problem` を渡して選択欄の下に出す、または `GrantPage.vue` の選択欄のすぐ下に `<ErrorMessage v-if="store.file && store.fileProblem" :message="store.fileProblem" />` を置く
2. ボタンの下は API のエラーだけにする（`<ErrorMessage v-if="store.error" :message="store.error" />`）
3. `errorMessage` は使わなくなるので、ストアから消すか、テスト（`test/store.test.ts` の `errorMessage`）とともに残すかを決める
4. 2つが同時に出ることがある（画像の問題と、前の API のエラー）。別の画像を選ぶと API のエラーは消えるので、ふつうは同時には出ない

### 3.3 見た目を変える（例: 画面の上に重ねて出す、数秒で消す）

1. 新しい部品（例: `src/components/ErrorToast.vue`）を作り、`message` を受け取って表示する（`role="alert"` は残す。画面の読み上げで、エラーが出たことが伝わるため）
2. 2つの `GrantPage.vue` の `<ErrorMessage …>` を新しい部品に置き換える
3. 数秒で消す場合は、送る前の問題（直すまで送れない）が消えて見えなくならないようにする（送る前の問題は消さない、など）

### 3.4 方式をまたいで1か所で変えられるようにする（任意）

今は、表示位置の1行が2つの `GrantPage.vue` にある。位置や見た目をよく変えるなら、ストアを読む部品（例: `src/components/GrantError.vue`。中身は `<ErrorMessage v-if="store.errorMessage" … />`）を作り、2つの `GrantPage.vue` はその部品を置くだけにすると、見た目の変更は1ファイルで済む（置く場所は各 `GrantPage.vue` のまま）。

### 3.5 文言を変えたいとき（参考）

- 送る前の確認の文言: `src/stores/ticket.ts` の `checkFile`・`tooLarge`
- API の結果の文言: `src/stores/ticket.ts` の `messageFor`（エラーコードごと）
- 文言の中身をテストで確かめているもの: `test/store.test.ts`（`checkFile`・`messageFor` の表）、`src/modes/page/page.test.ts`（REJECT・RETRY）。エラーの文言は、エラーコードとの対応を確かめる意味があるので、中身まで確かめている（説明文とは扱いが違う。../DESIGN.md 10章）。文言を変えたら、ここも直す
- ../DESIGN.md 4.4 の表も直す
