# 【一時メモ】ブラウザ側での画像の圧縮: ライブラリの比較

> 一時的な検討メモ（2026-10-06）。方針が決まったら [../DESIGN.md](../DESIGN.md) に反映し、このファイルは削除する。実装はしていない。数値は npm と GitHub の公開情報、ライブラリの README からの調査で、実機での計測はしていない。

## 1. 背景: 今の前提が変わる

今の設計は「写真は加工せず、そのまま送る」（パススルー）。進み具合（[upload-progress.md](upload-progress.md)）を検討していたのも、この前提で写真が大きいまま送られるため。ブラウザで圧縮すると、次のことが変わる。

| 項目 | パススルー（今） | ブラウザで圧縮 |
|---|---|---|
| 送るサイズ | 写真のまま。iOS が JPEG に変換した写真は 4MB の上限を超えることがある | 数百KB〜1MB 程度にできる（長辺と画質の設定しだい） |
| 送信の時間・進み具合 | 長くなりやすく、進み具合がほしい | 短くなり、進み具合の必要性は下がる |
| 画像解析サーバーに届くもの | 撮った写真そのもの（HEIC / AVIF / WebP なども） | ブラウザが作り直した JPEG（解像度と画質が落ちる） |
| EXIF（位置情報など） | そのまま届く | 既定では消える（プライバシーの面では利点） |
| ブラウザの負担 | なし | 写真をデコードして描き直す（古い端末では数百ミリ秒〜秒単位。未計測） |

- **最初に決めること**: 画像解析サーバーが、圧縮した画像で十分か（必要な解像度、形式、EXIF の要否）。DESIGN.md 7章の「画像の中身はパススルー」と、web/DESIGN.md の「画像の縮小・変換ライブラリは採用しない」を変えることになる
- 圧縮に失敗したとき（デコードできない、メモリ不足など）は、**元の写真をそのまま送る**ようにすれば、今の動きより悪くはならない

## 2. 候補の一覧（2026-10-06 時点）

| 候補 | 最新版（日付） | 週間ダウンロード | GitHub | サイズ（min + gzip） | 依存 | ライセンス |
|---|---|---|---|---|---|---|
| **Compressor.js**（`compressorjs`） | 1.4.0（2026-10-01） | 約54万 | 約5.8k スター、未解決の課題 3 | **約4.7KB** | `is-blob`、`blueimp-canvas-to-blob` | MIT |
| **browser-image-compression** | 2.0.2（**2023-03-06**） | **約178万** | 約1.7k スター、未解決の課題 65、最後の更新 2024-03 | 約20KB（PNG 用の `uzip` を含む） | `uzip` | MIT |
| **image-blob-reduce**（pica の上に作られたもの） | 5.0.1（2026-07-06） | 約82万 | pica は約4.2k スター（2026-08 更新） | 約24KB（pica を含む） | `pica` | MIT |
| pica（縮小だけ） | 10.0.3（2026-08-15） | 約100万 | 同上 | 約15KB | `glur`、`multimath` | MIT |
| jSquash（`@jsquash/jpeg` など。Squoosh のコーデックを WebAssembly にしたもの） | jpeg 1.6.0（2025-05） | 約20万 | 約0.7k スター | WebAssembly で数百KB | なし | Apache-2.0 |
| 自前（`<canvas>` と `toBlob()`） | - | - | - | 数十行 | なし | - |
| （補助）heic2any（HEIC を JPEG に変換） | 0.0.4（2023-03） | 約172万 | 未解決の課題 25 | 約2.7MB（展開時） | なし | MIT |

- jSquash は画質（mozjpeg）が最も良いが、WebAssembly が大きく、iOS 13 での動作も未確認。今回の用途には重い
- 自前の実装は、ライブラリにしたい方針（生っぽい処理は外部のものに任せる）に合わないので、比較の基準として挙げるだけにする
- heic2any は圧縮ではなく、ブラウザが読めない HEIC を JPEG にするための補助。大きく、更新も止まっているので、使わない方向（4.1）

## 3. 主な3候補の比較

| 観点 | Compressor.js | browser-image-compression | image-blob-reduce |
|---|---|---|---|
| 保守 | 2026年に2回リリース。課題が少ない | 2023-03 から更新なし。未解決の課題が多い | 2026年に更新（pica も） |
| サイズ | **最小（約4.7KB）** | 約20KB | 約24KB |
| 書き方 | コールバック（`new Compressor(file, { success, error })`。Promise にするには包む） | **Promise**（`await imageCompression(file, options)`） | Promise（`await reduce.toBlob(file, { max })`） |
| 中断 | `abort()` メソッド | **`AbortSignal`**（`signal` オプション） | pica の `cancelToken` |
| 縮小の指定 | `maxWidth` / `maxHeight`、`quality`、`mimeType`、`convertSize`（大きな PNG を JPEG にする） | `maxWidthOrHeight`、**`maxSizeMB`（目標のファイルサイズ。画質を下げながら繰り返す）**、`initialQuality`、`fileType` | `max`（長辺）だけ。画質の指定は差し替えで行う（既定は JPEG の 0.8） |
| 縮小の画質 | ブラウザの `drawImage` の縮小（標準的） | 同左 | **高画質**（Lanczos などのフィルター、シャープ化） |
| 処理する場所 | メインスレッド（処理中は画面が止まる） | Web Worker（OffscreenCanvas がある場合だけ。iOS は 16.4 以降）。ない場合はメインスレッド | Web Worker（pica。WebAssembly も使う）。使えなければメインスレッド |
| 進み具合 | なし | `onProgress`（圧縮の進み具合） | なし |
| 写真の向き（EXIF） | `checkOrientation`（既定で有効） | `exifOrientation` | JPEG の向きを適用する |
| EXIF の扱い | 既定で消す（`retainExif` で残せる） | 既定で消す（`preserveExif` で残せる） | **既定で残す**（位置情報も残るので、消すには差し替えが要る） |
| CSP（`script-src 'self'`） | 問題なし（Worker を使わない） | Worker を使うと `blob:` と、既定では **CDN（jsDelivr）からの読み込み**が必要。`libURL` で自分のサイトのファイルにすれば CDN は不要 | pica の分割ビルド（`pica_worker.js` を自分のサイトに置く）なら `blob:` も不要 |
| iOS の canvas の上限への対策 | `maxWidth` / `maxHeight` を 4096 以下にするよう README で推奨 | ブラウザごとの canvas の上限より小さく自動で縮める | pica が大きな画像を分割（タイル）して処理する |
| Vue 3.5 / 3.6 との相性 | Vue に依存しない（`File` を受けて `Blob` を返すだけ）。影響なし | 同左 | 同左 |
| 型定義 | 同梱（1.4.0 で改善） | 同梱 | 同梱（pica の型に依存） |
| TypeScript 7（5章） | **TS 6・7 とも問題なし（`bundler`・`nodenext` の両方）** | `bundler` は問題なし。`nodenext` では既定のエクスポートが呼び出せない型になる | `bundler` は問題なし。`nodenext` では pica の型が解決できない |

## 4. どのライブラリでも共通の課題

### 4.1 HEIC（iPhone の写真）

- ブラウザで圧縮するには、まずブラウザが写真をデコード（`<img>` や `createImageBitmap`）できる必要がある
- Safari が HEIC をデコードできるのは **iOS 17 から**。iOS 13〜16 と、Android の Chrome は HEIC をデコードできない
- 対策の候補:
  - **`<input>` の `accept` から `image/heic` を外す**: iOS は、写真を選んだときに JPEG に変換して渡すとされる（実機で要確認）。圧縮するなら、こちらの方が確実
  - デコードできない写真は、**圧縮せずにそのまま送る**（API は HEIC を受け付けるので、今と同じ動きになる）
  - heic2any で JPEG にする: 大きく（約2.7MB）、更新も止まっているので、使わない方向

### 4.2 iOS の canvas の上限

- Safari は、1つの canvas が 16,777,216 ピクセル（4096×4096）を超えると描けない。canvas の合計のメモリにも上限がある（iOS 15 で 384MB。古い iOS や端末ではもっと小さい）。超えると、真っ白な画像になったり、エラーになったりする
- 12MP（4032×3024）の写真はぎりぎり収まるが、48MP の写真は収まらない。**長辺を 4096 以下（実用的には 2048〜2560 程度）に縮める**設定にする

### 4.3 そのほか

- 写真の向き: 新しいブラウザは描くときに EXIF の向きを自動で適用する。ライブラリの向きの処理と二重にならないかを、実機で確かめる
- 処理時間: Android 9 の古い端末では、デコードと描き直しに時間がかかる可能性がある（未計測）。Web Worker を使えるライブラリなら、画面は止まらない
- 圧縮の結果が元より大きくなる場合（すでに小さい写真など）は、元の写真を送る

## 5. Vue 3.5 / 3.6 と TypeScript 7 との相性

### 5.1 Vue

- 3候補とも、Vue に依存しない（`File` を受け取って、縮めた `Blob` / `File` を返すだけ）。Vue の版に関係なく使え、Vue 3.5 から 3.6 に上げても影響しない
- Vue 3.6 は、2026-10-06 時点で RC（`3.6.0-rc.10`、2026-09-30）。正式版は 3.5.43。3.6 の大きな変更（Vapor モードなど）は描画の仕組みの話で、これらのライブラリの使い方には関係しない
- 組み込み方は、ストア（Pinia）の送信の前に、圧縮の関数を1つはさむだけ。Vue のコンポーネントのラッパーは要らない
- Web Worker を使う場合のファイルの置き方（Vite）: pica（image-blob-reduce）は分割ビルドの `pica_worker.js` を `new URL('pica/dist/pica_worker.js', import.meta.url)` で自分のサイトから読める。browser-image-compression は `libURL` に自分のサイトのファイルを指定する（既定は CDN）

### 5.2 TypeScript 7

各ライブラリの使い方の例（圧縮して `Blob` / `File` を受け取るコード）を、TypeScript 6.0.3（web が今使っている版）と 7.0.2 で型チェックした（`strict`、`verbatimModuleSyntax`、型定義のチェックも有効）。

| | `moduleResolution: bundler`（web の設定） | `moduleResolution: nodenext`（ESM） |
|---|---|---|
| Compressor.js | TS 6・7 とも問題なし | TS 6・7 とも問題なし |
| browser-image-compression | TS 6・7 とも問題なし | TS 6・7 とも型エラー（既定のエクスポートが呼び出せない型になる） |
| image-blob-reduce | TS 6・7 とも問題なし | TS 6・7 とも型エラー（pica の型が解決できない） |

- **TypeScript 6 と 7 で結果は同じ**だった。TypeScript 7 に上げても、これらのライブラリの型で新しく困ることはない
- `nodenext` の型エラーは、パッケージの型定義の作り方の問題（TypeScript の版とは関係ない）。web は Vite の `bundler` 設定なので、今は影響しない
- 型定義の作りが最も素直で、設定に左右されないのは Compressor.js
- web を TypeScript 7 に上げられない理由は、これらのライブラリではなく **vue-tsc**（Vue のテンプレートの型チェック）。vue-tsc 3.3.12 は TypeScript 7 では起動しない（web/DESIGN.md 2章で TS 6 に固定した理由）。vue-tsc が TypeScript 7 に対応すれば、どの候補を選んでも、そのまま上げられる

## 6. 評価（案）

| 重視すること | 向いている候補 |
|---|---|
| 小さく、保守が続いていて、単純。TypeScript 7 でも型が素直に使える | **Compressor.js** |
| ファイルサイズの上限を確実に守る（`maxSizeMB`）、`AbortSignal`、圧縮の進み具合 | browser-image-compression（ただし 2023 年から更新がない点と、CSP のための設定が要る点に注意） |
| 縮小の画質（画像解析の精度に効く可能性）、画面を止めない処理 | image-blob-reduce（ただし既定で EXIF を残すので、位置情報を消す処理を足す） |

- **第一候補は Compressor.js**: 4.7KB と最小で、2026 年にも更新されている。今回の用途（長辺を 2048 程度に縮めて JPEG にする）なら、必要な機能はそろっている。型定義の作りも素直で、TypeScript 6・7 のどちらでも、どの設定でも問題がない。メインスレッドで動くが、写真1枚なら許容できる見込み（実機で確かめる）
- 画像解析の精度のために縮小の画質を重視するなら、image-blob-reduce を比べる
- browser-image-compression は利用者が最も多く、機能も多いが、2023 年から更新が止まっていて未解決の課題も多いので、長く使う前提では選びにくい

## 7. 決めること

1. ブラウザで圧縮するか（パススルーの方針を変えるか）。画像解析サーバーが必要とする解像度・形式・EXIF の要否を確かめてから決める
2. 圧縮の設定: 長辺の上限（例: 2048）、画質（例: 0.8）、出力の形式（JPEG）
3. HEIC の扱い: `accept` から `image/heic` を外すか。デコードできない写真は、そのまま送るか
4. 失敗したとき・圧縮して大きくなったときは、元の写真を送るか（推奨: 送る）
5. EXIF（位置情報）を消すか（推奨: 消す。ライブラリの既定で消えるものを選ぶか、消す処理を足す）
6. ライブラリ（第一候補: Compressor.js）
7. 圧縮するなら、アップロードの進み具合（upload-progress.md）はやめるか

## 8. 参考

- npm と GitHub の公開情報（バージョン、日付、ダウンロード数、スター、課題の数）、各ライブラリの README
- TypeScript 6.0.3 / 7.0.2 での型チェック（2026-10-06。使い方の例のコードで確認）
- [HEIF/HEIC image format - Can I use](https://caniuse.com/heif)
- [HEIC Browser Support 2026: Chrome, Safari & More](https://www.heicify.com/guides/heic-browser-support)
- [Rendering HEIC on the web - DEV Community](https://dev.to/upsidelab/rendering-heic-on-the-web-how-to-make-your-web-app-handle-iphone-photos-pj1)
- [Canvas Area Exceeds The Maximum Limit - Pqina](https://pqina.nl/blog/canvas-area-exceeds-the-maximum-limit/)
- [Total Canvas Memory Use Exceeds The Maximum Limit - Pqina](https://pqina.nl/blog/total-canvas-memory-use-exceeds-the-maximum-limit/)
- [pica: iOS Memory Limit](https://github.com/nodeca/pica/wiki/iOS-Memory-Limit)
