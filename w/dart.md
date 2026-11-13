# Dart で Wasm を作る検証

作成日: 2026-11-13
状態: ①〜③ は完了。④（Wasmtime で動かすために取り込み関数を Wasm で用意する）は、Dart 3.13.7 の出力が Wasmtime で読み込めないことが分かったため、手前で止めた（5 章）

`other-languages.md` の 4 章の調査をもとに、Dart の mandel を Wasm にして、ブラウザ・Node.js・Deno・Wasmtime・wazero で動かした。

---

## 用語

| 名前 | 指すもの |
|---|---|
| **ブラウザ向けの Wasm** | `dart compile wasm` の通常の出力。`.wasm` と起動用の JS（`.mjs`）の組。JS の文字列の組み込み機能（`wasm:js-string`）を使う |
| **独立モードの Wasm** | `dart compile wasm --standalone` の出力。JS を使わない代わりに、Dart 独自の取り込み関数（`dart` モジュール）を求める |
| **取り込み関数（Dart）** | 独立モードの Wasm がホストに用意してもらう関数。文字列の操作、数値の文字列化、時刻、出力など。SDK の `embedder.dart` に 82 個が定義されていて、使わないものはビルドのときに削られる |
| **補助モジュール** | WasmGC の配列を JS から読み書きするために書いた、小さな Wasm（`dart/run/gc-helper.wat`） |
| **WasmGC** | ガベージコレクションを実行環境に任せる Wasm の機能。Dart の Wasm はこれを使う |
| **古い形式の例外処理（legacy exceptions）** | Wasm の例外処理の最初の形式（`try` / `catch` 命令）。標準になったのは新しい形式（`try_table` / `exnref`） |

---

## 1. 環境

| もの | 版 |
|---|---|
| Dart SDK | **3.13.7**（Homebrew の `dart-sdk`。最新は 3.14.0） |
| Node.js / Deno | v26.13.0 / 2.9.8 |
| Chrome（ヘッドレス） | 157 |
| Wasmtime | 50.0.1（ホスト。コンテナも同じ版） |
| wazero | 1.12.0（コンテナ） |

取得したものはない（Dart SDK は利用者が入れていた）。

---

## 2. 作ったもの

```
dart/
├─ mandel/                       mandel の Dart 版（go/mandel と同じ計算）
│   ├─ bin/mandel.dart
│   └─ pubspec.yaml
└─ run/
    ├─ run-browser-target.mjs    ブラウザ向けの Wasm を Node.js / Deno で動かす
    ├─ run-standalone.mjs        独立モードの Wasm を、取り込み関数を JS で用意して動かす
    └─ gc-helper.wat             補助モジュール（WasmGC の配列の読み書き）
web/dart.html                    ブラウザで Wasm と JS（dart2js）を比べるページ
```

`bench/bench-browser.mjs` は、環境変数 `PAGE` で開くページを変えられるようにした（`PAGE=dart.html`）。

**ビルド**（`dart/mandel` で実行。4 つ合わせて約 3 秒）

```sh
dart compile exe  -DIMPL=dart-native bin/mandel.dart -o ../../dist/mandel-dart-native
dart compile js   -O2 -DIMPL=dart-js bin/mandel.dart -o ../../dist/dart-js/mandel.js
dart compile wasm -O2 -DIMPL=dart-wasm bin/mandel.dart -o ../../dist/dart-wasm/mandel.wasm
dart compile wasm -O2 --standalone -DIMPL=dart-wasm-standalone bin/mandel.dart -o ../../dist/mandel-dart-standalone.wasm
```

**大きさ**

| 出力 | 大きさ |
|---|---:|
| ネイティブ（`dart compile exe`） | 5.7 MB |
| JS（`dart compile js -O2`） | 47 KB |
| **ブラウザ向けの Wasm** | **19 KB**（＋起動用の JS 6.5 KB） |
| **独立モードの Wasm** | **8.5 KB** |
| 参考: hello の独立モードの Wasm | 15.7 KB（`-O2` なし） |

これまでに作った mandel の Wasm で最も小さい（Embedded Swift 67 KB、Rust の wcount 72 KB、TinyGo 1.36 MB、Go 4.5 MB）。ガベージコレクションを実行環境（WasmGC）に任せるので、言語のランタイムをほとんど含まないため。

---

## 3. 実行環境ごとの結果

| 経路 | 実行環境 | 結果 |
|---|---|---|
| ① ブラウザ向けの Wasm | Chrome（ヘッドレス） | **動いた**。checksum 218222850 |
| ② ブラウザ向けの Wasm | Node.js / Deno | **動いた**。起動用の JS（`.mjs`）をそのまま使えた |
| ③ 独立モードの Wasm ＋ JS の取り込み関数 | Node.js / Deno | **動いた**。取り込み関数 15 個を JS で用意した |
| 独立モードの Wasm | Wasmtime 50.0.1 | **動かない**。`legacy_exceptions feature required for try instruction`（5 章） |
| 独立モードの Wasm | wazero 1.12.0 | **動かない**。`section type: read 0-th type: invalid byte: 0x50 != 0x60`（WasmGC の型を読めない） |

### 3-1. ③ 独立モードで必要だった取り込み関数（15 個）

`print`、`stringFromAsciiBytes`、`i64ToString`、`stringBufferCreate`、`stringBufferWriteString`、`stringBufferToString`、`stringLength`、`stringConcat`、`stringRepeat`、`stringCodeUnitAt`、`jsonEncodeString`、`stackTraceGetCurrent`、`stackTraceToString`、`monotonicClockFrequency`、`monotonicClockTicks`

- 文字列は JS の文字列を `externref` としてそのまま受け渡す。
- `stringFromAsciiBytes` は文字列のもとになるバイト列を WasmGC の配列（`(array (mut i8))`）で受け取る。WasmGC の配列は JS から中身を読めないので、補助モジュールの `bytesGet` で 1 バイトずつ読む。型の定義が同じなら、モジュールが違っても同じ型として扱われる（WasmGC の型の同一性の規則）ので、この方法が使えた。
- 小数の文字列化（`f64ToString`）が要らないように、mandel の出力ではマイクロ秒の整数から時間を組み立てた。

### 3-2. 独立モードでは `main` に引数が渡らない

入口の `$invokeMain` は引数の配列（`(array (mut externref))`）を受け取るが、Dart 3.13.7 の出力はその引数を一度も読んでいない（WAT で確認）。そのため、独立モードでは `main` の引数がいつも空になる。mandel は既定の条件（1200×900、最大反復 1000）でだけ動かした。

---

## 4. 速さ

### 4-1. CLI（Node.js、Deno。各 5 回の中央値。1 回の起動で 1 回だけ計算する）

| 実装 | 計算時間 (ms) | 全体の時間 (ms) |
|---|---:|---:|
| Dart ネイティブ | 413.8 | 423.6 |
| ブラウザ向けの Wasm on Node.js | 1,148.2 | 1,192.9 |
| ブラウザ向けの Wasm on Node.js（`--no-liftoff`） | 845.1 | 899.7 |
| ブラウザ向けの Wasm on Deno | 1,083.9 | 1,110.2 |
| 独立モードの Wasm on Node.js | 1,083.5 | 1,128.6 |
| 独立モードの Wasm on Node.js（`--no-liftoff`） | 861.4 | 914.5 |
| 独立モードの Wasm on Deno | 1,143.6 | 1,170.2 |

checksum はすべて 218222850。Go ネイティブは約 386 ms で、Dart ネイティブはそれより約 7% 遅い。

### 4-2. ブラウザ（ヘッドレスの Chrome 157。同じページで 5 回続けて計算）

| 実装 | 起動 | 計算 1 回目 | 計算 2 回目以降（中央値） |
|---|---:|---:|---:|
| ブラウザ向けの Wasm | **7.7 ms**（取得・コンパイル・インスタンス化） | 1,158.9 ms | **385.2 ms** |
| JS（dart2js） | — | 392.8 ms | 391.1 ms |

### 4-3. 同じプロセスで続けて計算した場合（Node.js。ブラウザ向けの Wasm）

| | 1 回目 | 2 回目 | 3 回目 | 4 回目 |
|---|---:|---:|---:|---:|
| 既定 | 1,150 ms | **385 ms** | 387 ms | 385 ms |
| `--no-liftoff` | 846 ms | 845 ms | 845 ms | 845 ms |

---

## 5. 分かったこと

- **Dart の Wasm はとても小さい**: mandel で 8.5〜19 KB。WasmGC にガベージコレクションを任せるので、ランタイムをほぼ含まない。起動も速い（ブラウザで 7.7 ms）。
- **最適化された後はネイティブと同じ速さ**: ブラウザや同じプロセスで 2 回目以降は約 385 ms で、Go ネイティブ（386 ms）や Dart ネイティブ（414 ms）と同じか速い。
- **`--no-liftoff` にすると、かえって遅いまま止まる**（845 ms）。これまでの言語（Go、TinyGo、Swift、C#）では、`--no-liftoff` でネイティブ並みになっていたので、逆の結果になった。
  - 推測: V8 は、WasmGC を使う Wasm を最適化するとき、Liftoff のコードで動いている間に集めた情報（実際に来た型や呼ばれた関数）をもとに、関数のインライン展開などを推測で行う。`--no-liftoff` だとその情報が集まらないので、最適化しても遅いままになる。
  - 1 回の起動で 1 回だけ計算する CLI の使い方では、Dart の Wasm は不利（1,080〜1,150 ms）。同じインスタンスを何度も呼ぶ使い方（ブラウザ、サーバー、組み込み）なら速い。
- **ブラウザの外では、まだ実用の段階ではない**:
  - Wasmtime: Dart 3.13.7 の出力が古い形式の例外処理を使っていて、Wasmtime 50 はその形式を受け付けない（有効にする設定もない）。
  - wazero: WasmGC に対応していない。
  - 独立モードは「実験的。取り込み関数は今後の版で変わりうる」と明記されている。
  - 独立モードでは `main` に引数が渡らない（3-2）。

---

## 6. ④（Wasmtime で動かす）について

**手前で止めた理由**: ④ は「取り込み関数を WAT で書き、WASI につないで Wasmtime の `--preload` で一緒に読み込ませる」計画だったが、その前に、Dart 3.13.7 の出力そのものを Wasmtime が読み込めないことが分かった。

**続けるなら**:

1. Dart を **3.14.0**（最新）に上げて、出力の例外処理が新しい形式（`try_table`）に変わるかを確かめる（資料の「Wasmtime 39 以降で `-W gc,exceptions,function-references=y`」はこれを前提にしているとみられる。未確認）
2. 変わっていれば、15 個の取り込み関数を WAT で書く。文字列は、Wasm の中では GC の配列で表し、`extern.convert_any` でホスト側の値（`externref`）に変換して受け渡す。出力は WASI の `fd_write`、時刻は `clock_time_get` につなぐ
3. Wasmtime（ホストとコンテナ）で動かす

**必要なもの**: Dart SDK 3.14.0（ホスト。`brew upgrade dart-sdk`）。

---

## 7. 確かめていないこと

- Dart 3.14.0 で例外処理の出力が新しい形式に変わったか
- `--no-liftoff` で遅いままになる理由（4-3 の推測）。V8 の推測による最適化の設定を変えて確かめる方法を調べていない
- Node.js / Deno での JS（dart2js）の速さ（ブラウザでだけ計った）
- Safari（JavaScriptCore）での速さ

---

## 参照した情報

- [Dart: WebAssembly (Wasm) compilation](https://dart.dev/web/wasm)
- [dart2wasm: Standalone mode](https://dart.googlesource.com/sdk/+/stable/pkg/dart2wasm/docs/standalone.md)
- [dart2wasm の embedder.dart（独立モードの取り込み関数の定義）](https://dart.googlesource.com/sdk/+/stable/sdk/lib/_internal/wasm/standalone/embedder.dart)
- [dart-lang/sdk #53884（独立モードの追跡 issue）](https://github.com/dart-lang/sdk/issues/53884)
