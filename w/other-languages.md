# mruby・MicroPython・Dart の Wasm 対応の整理

作成日: 2026-11-12（机上の調査）
更新: 2026-11-13。mruby と MicroPython は、インタープリター同梱型のため速さと大きさが期待できないので、いったん保留にした。Dart は検証した（`dart.md`）

`runtimes.md`（Go、TinyGo、Rust、手書き）と `swift-csharp.md`（Swift、C#）に続く候補として、mruby、MicroPython、Dart が Wasm でどこまで動くかを調べた。判定はネットの資料にもとづくもので、この Mac では試していない。

---

## 用語

| 名前 | 指すもの |
|---|---|
| **インタープリター同梱型** | 言語のインタープリター（実行系）そのものを Wasm にし、その上でスクリプトを解釈して動かす形。mruby と MicroPython はこちら（`runtimes.md` の 8-4 の「インタープリターごと入れる」形） |
| **コンパイル型** | ソースを Wasm の命令に変換する形。Dart はこちら |
| **WasmGC** | ガベージコレクションを実行環境に任せる Wasm の機能。対応していない実行環境（wazero など）では動かない |
| **独立モード（Dart）** | `dart compile wasm --standalone`。ブラウザの外の実行環境（Wasmtime など）向けに出力するモード |
| **4 つの実行環境** | この作業で比べている Wasmtime、wazero（どちらもコンテナ）、Node.js、Deno |

---

## 1. 全体の比較

| | mruby | MicroPython | Dart |
|---|---|---|---|
| 形 | インタープリター同梱型（RiteVM） | インタープリター同梱型 | コンパイル型（WasmGC を使う） |
| ブラウザ | **公式**（Emscripten 向けのビルド設定 `build_config/emscripten.rb`）。動作のお試し程度の位置づけ | **公式**（`ports/webassembly`、Emscripten）。PyScript の軽量版の土台 | **公式**（`dart compile wasm`。Flutter の Web 版でも使われている） |
| WASI（CLI） | 公式にはない。第三者の `mruby_wasi`（2022 年で更新が止まっている） | 公式にはない。第三者の `micropython-wasm`（2026 年 6 月、アルファ版） | 独立モードで Wasmtime 39 以降に対応。ただし WASI ではなく Dart 独自の取り込み関数が要る |
| 大きさ | 未確認 | ブラウザ版は約 303 KB（2022 年の数字）。WASI 版は 362 KB | 未確認 |
| 4 つの実行環境で動くか | 未確認 | WASI 版なら動く見込み（未確認） | wazero では動かない（WasmGC 非対応）。ほかは取り込み関数を用意すれば動く可能性 |
| 向いている用途 | 小さな Ruby の実行系を組み込む。ブラウザでの Ruby | 小さな Python の実行系。信用できないコードを隔離して動かす | ブラウザのアプリ（Flutter）。ブラウザの外は実験段階 |

---

## 2. mruby

### 2-1. ブラウザ（Emscripten）

- mruby 本体に Emscripten 向けのクロスビルドの設定がある（`build_config/emscripten.rb`。mruby 3.4.0 で確認）。
- 追加したときの PR（#4486）には「mruby の RiteVM を Wasm の VM の上で動かすもので、性能を狙ったものではなく動かしてみせるためのもの」とある。
- 既知の問題: ビルドの設定に通常のビルドとクロスビルドを両方書くと、Emscripten のクロスビルドの途中でホスト用のプログラムを動かそうとして失敗する（issue #5453）。

### 2-2. WASI

- 公式の対応は見つからなかった。
- 第三者の `mruby_wasi`（2022 年）は、例外の処理で使う C の `setjmp` / `longjmp` が当時の WASI で使えなかったため、作者が「今のところ使えない」と書いている。
- 最近の WASI SDK は、Wasm の例外処理の機能を使って `setjmp` / `longjmp` に対応してきているので、今ならビルドできる可能性がある（**未確認**）。

### 2-3. 関連する実装

| 実装 | 内容 |
|---|---|
| **PicoRuby.wasm** | mruby 互換の別の実装 PicoRuby の Wasm 版。npm の `@picoruby/wasm-wasi`（v0.9.6）。ブラウザで Ruby を動かせる。小さくするため、async/await には対応していない。RubyKaigi 2026 で、これを使ったブラウザ向けの枠組み（Funicular）が発表された |
| **ruby.wasm** | 通常の Ruby（CRuby）の Wasm 版。ブラウザと WASI の両方に対応。mruby より大きい |
| **mruby.wasm（elct9620）** | ブラウザ向けのつなぎ（WebIDL）を持つ試作。安定版ではない |

---

## 3. MicroPython

### 3-1. ブラウザ（Emscripten）

- 公式の `ports/webassembly` が Emscripten 向けで、JS から使う形。
- PyScript の軽量版の土台になっている。2022 年の時点で約 303 KB、起動は 100 ms 未満。CPython を Wasm にした Pyodide（約 6.5 MB、圧縮後）よりずっと小さい。

### 3-2. WASI

- 公式には、`ports/unix` を WASI に対応させる実験的な PR が話題になっているが、取り込まれたかは確かめられなかった。
- 第三者の `micropython-wasm`（2026 年 6 月、アルファ版、Apache-2.0）は、MicroPython を WASI の Wasm（362 KB）にしたもので、Wasmtime で動かす。信用できないコードを隔離して動かす目的で作られている。

### 3-3. この作業との相性

WASI 版が手に入れば、hello や mandel と同じように 4 つの実行環境とブラウザ（`web/wasi-shim.js`）で試せる見込み。インタープリター同梱型なので、計算の速さはコンパイル型に大きく劣るはず。

---

## 4. Dart

### 4-1. ブラウザ

- `dart compile wasm` が公式で、WasmGC を使う。Flutter の Web 版でも使われている。
- 出力はブラウザ（JS の環境）で動かす前提で、JS のつなぎのコードと一緒に使う。

### 4-2. ブラウザの外（独立モード）

`dart compile wasm --standalone` を付けると、Wasmtime 39 以降で動かせる。ただし次の制約がある。

| 制約 | 内容 |
|---|---|
| Wasmtime の設定 | GC、例外、関数の参照の 3 つの機能を有効にする（`-W gc,exceptions,function-references=y`） |
| 取り込み関数 | タイマー、スタックトレース、正規表現、`dart:math`、数値の文字列化などに、Dart 独自の取り込み関数が要る。WASI に置き換える案はまだ提案の段階 |
| 安定性 | 取り込み関数の形は「安定していない。今後の版で変わりうる」と明記されている |
| JS との連携 | 独立モードでは `dart:js_interop` が使えない |

### 4-3. コンポーネント（実験的）

pub の `wasm_tools` パッケージで、WASI 0.2 のコンポーネントを作る試みがある。非常に実験的で、Dart の SDK（3.13）にパッチを当てる必要がある。

### 4-4. この作業との相性

| 実行環境 | 見込み |
|---|---|
| Wasmtime | 独立モードで動く可能性。取り込み関数をどう用意するかが課題 |
| wazero | 動かない（WasmGC に対応していない） |
| Node.js / Deno / ブラウザ | V8 が WasmGC に対応しているので、取り込み関数を JS で用意すれば動く可能性 |

---

## 5. 試すとしたら

| 順 | 対象 | 方法 | 必要なもの |
|---|---|---|---|
| 1 | MicroPython | `micropython-wasm` の WASI の Wasm（362 KB）を 4 つの実行環境とブラウザで動かす。mandel を Python で書いて計る | パッケージの取得（小さい） |
| 2 | Dart | `dart compile wasm --standalone` で mandel を作り、Wasmtime で動かす。足りない取り込み関数を確かめる | Dart の SDK（ホスト。Homebrew の `dart`） |
| 3 | mruby | Emscripten でブラウザ向けをビルドする。WASI 向けは最近の WASI SDK でビルドできるかを試す | Emscripten または WASI SDK（C# のビルド用コンテナに WASI SDK 29.0 の arm64 版がある） |

**見るべき点**: インタープリター同梱型（mruby、MicroPython）は計算の速さではコンパイル型に大きく劣るはずなので、「大きさ」「起動の速さ」「隔離して動かす用途」を中心に見る。Dart は WasmGC を使うコンパイル型なので、Kotlin/Wasm などと同じく「どの実行環境で動くか」が主な論点になる。

---

## 参照した情報

- [mruby_wasi（awesome.ecosyste.ms）](https://awesome.ecosyste.ms/projects/github.com%2Fjasl%2Fmruby_wasi)
- [CRuby の wasm/README.md](https://git.ruby-lang.org/ruby.git/tree/wasm/README.md)
- [An Update on WebAssembly/WASI Support in Ruby](https://itnext.io/final-report-webassembly-wasi-support-in-ruby-4aface7d90c9)
- [mruby 3.4.0 の build_config/emscripten.rb（Debian のソース）](https://sources.debian.org/src/mruby/3.4.0-2/build_config/emscripten.rb)
- [mruby PR #4486: New Emscripten WebAssembly target + examples](https://www.github.com/mruby/mruby/pull/4486)
- [mruby issue #5453](https://www.github.com/mruby/mruby/issues/5453)
- [mruby.wasm（elct9620）](https://github.com/elct9620/mruby.wasm)
- [PicoRuby.wasm の README（npm）](https://cdn.jsdelivr.net/npm/@picoruby/wasm-wasi@0.9.6/README.md)
- [Funicular: A Browser App Framework Powered by PicoRuby.WASM（RubyKaigi 2026）](https://rubykaigi.org/2026/presentations/hasumikin)
- [PyScript updates: Bytecode Alliance, Pyodide, and MicroPython（Anaconda）](https://www.anaconda.com/blog/pyscript-updates-bytecode-alliance-pyodide-and-micropython)
- [MicroPython Technical Preview（PyScript）](https://pyscript.net/tech-preview/micropython/about.html)
- [micropython-wasm](https://ai-tldr.dev/tools/micropython-wasm/index.md)
- [Simon Willison's Weblog: micropython](https://simonwillison.net/tags/micropython/)
- [Dart: WebAssembly (Wasm) compilation](https://dart.dev/web/wasm)
- [dart2wasm: Standalone mode](https://dart.googlesource.com/sdk/+/stable/pkg/dart2wasm/docs/standalone.md)
- [wasm_tools（pub.dev）](https://pub.dev/documentation/wasm_tools/latest/)
- [WasmGC, Dart and Flutter: Where It Stands in 2026](https://foresightmobile.com/blog/wasmgc-and-how-this-is-a-game-changer-for-dart-and-flutter)
- [Flutter: Support for WebAssembly](https://docs.flutter.dev/development/platform-integration/web/wasm)
