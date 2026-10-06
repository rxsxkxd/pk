# 【一時メモ】アップロードの進み具合: Fetch Upload Streams と XMLHttpRequest の評価

> 一時的な検討メモ（2026-10-06）。検討中の案は [../DESIGN.md](../DESIGN.md) 2.3 に書いてある。方針が確定したら、このファイルは削除する。

## 1. 結論

**検討中（優先度は低い。2026-10-06）**: アップロードの進み具合は、**Android だけ** fetch のストリーム（Fetch Upload Streams）で出す案で考えている（DESIGN.md 2.3、11章の未確定事項7）。

- iOS の Safari は、最新の正式版（26.x）でも Fetch Upload Streams に対応していない（2章）。iOS では進み具合を出さない
- Android の Chrome 105 以降（Android 9 の Chrome 138 を含む）で進み具合を出す。ただし API Gateway が HTTP/2 で応答しない場合は使えない（未確認）
- 将来、Safari の正式版が対応すれば、機能の有無で判定するので、自動的に進み具合が出る
- 実装は保留

検討した別案（今回は採らない）: すべての対象ブラウザ（iOS 13 / Android 9 以上）で使える **XMLHttpRequest の `xhr.upload.onprogress`** で進み具合を出す案（3章）。メモリの面でも、写真を送る用途では fetch に劣らない（4章）。方針を見直すときのために、評価を残しておく

## 2. iOS の Fetch Upload Streams の対応状況

- WebKit は、開発者向けのプレビュー版 Safari Technology Preview 250（2026-08-13）で、`ReadableStream` をボディにした `fetch`（`duplex: 'half'`）に初めて対応した
- iOS の正式版の Safari（26.x）に入ったという情報は見つからなかった。当面、iOS では使えない（将来の Safari で使えるようになる可能性はある）
- 最近の iOS で増えた近い機能も、代替にならない: WebTransport（Safari 26.4 から）はサーバー側に WebTransport の実装が必要で、API Gateway + Lambda では受けられない。fetch のアップロードの進み具合のイベントは、どのブラウザにもない
- Chrome は 105 から対応（Android 9 の Chrome 138 も対応）。ただし HTTP/2 以上が必要で、API Gateway（execute-api）が HTTP/2 で応答するかは未確認

## 3. Fetch Upload Streams と XMLHttpRequest の比較

| | Fetch Upload Streams | XMLHttpRequest（`xhr.upload.onprogress`） |
|---|---|---|
| iOS（13〜最新） | 使えない | **使える** |
| Android 9（Chrome 138 まで） | 使える | 使える |
| 進み具合の精度 | ブラウザがストリームから読み出した量（実際に送った量より先に進む） | **実際にネットワークに送った量** |
| HTTP/2 | 必要 | 不要（HTTP/1.1 でもよい） |
| 送り方 | multipart を自分で組み立てる | `FormData` をそのまま渡せる |
| タイムアウト・中断 | `AbortController` | `xhr.timeout` と `xhr.abort()`（`AbortSignal` の中断を受けて `abort()` を呼べば、今の書き方に合わせられる） |
| CORS | 必ずプリフライトが発生する | アップロードのイベントを登録すると、プリフライトが発生する（仕様の決まり。API Gateway の CORS 設定で応答できる） |
| ブラウザごとの判定・フォールバック | 必要 | 不要（全ブラウザで同じ方法） |

## 4. メモリ効率（「XMLHttpRequest は fetch よりメモリ効率が悪い」は本当か）

ブラウザの実装の仕組みからの評価。実機での計測はしていない。

### 4.1 送信（アップロード）: 差はない

- `<input>` で選んだ `File` は、中身を JS のメモリに持たない「ディスク上のファイルへの参照」
- `xhr.send(formData)` でも `fetch(url, { body: formData })` でも、ブラウザのネットワーク処理がファイルを少しずつ読みながら送る。写真全体が JS のメモリに載ることは、どちらもない
- fetch が有利なのは、**JS の中でデータを作りながら送る場合**（Fetch Upload Streams）だけ。すでにファイルとしてある写真を送るときは、この利点は出ない

### 4.2 受信（ダウンロード）: 差は出るが、今回は影響しない

- fetch は `response.body` をストリームとして少しずつ処理できる。XMLHttpRequest は応答全体を受け取ってから扱い、既定の `responseType`（テキスト）では受信中も `responseText` が伸び続ける
- 今回の応答は小さな JSON（チケット付与 API は数百バイト、QR 同梱付与 API でも数KB）なので、影響しない
- XMLHttpRequest を使うときは `responseType = 'json'` を指定する（応答をテキストとして持たずに済む）

### 4.3 OS・ブラウザごとの違い

| 環境 | 実装 |
|---|---|
| iOS（Safari、Chrome などすべてのブラウザ） | どれも WebKit で動く。XMLHttpRequest と fetch は同じ通信の仕組み（ネットワーク用の別プロセス）を通り、ファイルの送信はどちらもディスクから順に読む |
| Android（Chrome、WebView） | Blink（Chromium）。XMLHttpRequest と fetch は同じ読み込みの仕組みの上にある |

- iOS で写真を選ぶと、ブラウザが一時ファイルを作ることがある（形式の変換など）。これは XMLHttpRequest でも fetch でも同じ

### 4.4 メモリで本当に気をつけること

- 写真を JS で読み込まないこと（`FileReader.readAsDataURL()`、`file.arrayBuffer()`、プレビューのための `<canvas>` への描画など）。写真全体（base64 なら約1.33倍）が JS のメモリに載る
- 今の設計はプレビューを出さず、写真をそのまま送るので、この心配はない

### 4.5 実機で確かめるなら

同じ写真を XMLHttpRequest と fetch の両方で送り、メモリを比べる。

- iPhone: Mac の Safari の Web インスペクタ（タイムラインのメモリ）
- Android: Chrome のリモートデバッグ（`chrome://inspect`）

## 5. 参考

- [Streaming requests with the fetch API - Chrome for Developers](https://developer.chrome.com/docs/capabilities/web-apis/fetch-streaming-requests)
- [Announcing Interop 2026 - WebKit](https://webkit.org/blog/17818/announcing-interop-2026/)
- [Release Notes for Safari Technology Preview 250 - WebKit](https://webkit.org/blog/18191/release-notes-for-safari-technology-preview-250/)
- [WebKit Features for Safari 26.4](https://webkit.org/blog/17862/webkit-features-for-safari-26-4/)
- [fetch-with-streams/streaming-upload.md](https://github.com/yutakahirano/fetch-with-streams/blob/master/streaming-upload.md)
- [Fetch streams are great, but not for measuring upload/download progress - JakeArchibald.com](https://jakearchibald.com/2025/fetch-streams-not-for-progress/)
- [Has fetch() caught up with XMLHttpRequest in JavaScript?](https://waspdev.com/articles/2025-10-10/has-fetch-caught-up-with-xhr)
- [Tracking Upload Progress in Browsers - Siaw Young](https://www.siawyoung.com/xhr-upload-progress/)
