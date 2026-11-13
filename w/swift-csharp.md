# Swift と C# で Wasm を作る検証

作成日: 2026-11-12
状態: 段階 0・段階 1（Swift、Embedded Swift を含む）・段階 2 の B（C# の componentize-dotnet）が完了（2026-11-12）。C# の A（ブラウザ向け）も .NET 10（5 章）と .NET 11 の Mono・CoreCLR（6 章、2026-11-13）まで完了。性能差について確かめていないことは `perf-open-questions.md` にまとめた

`runtimes.md` で Go、TinyGo、Rust、手書きの Wasm を 4 つの実行環境（Wasmtime、wazero、Node.js、Deno）とブラウザで比べた。この文書では、残っていた Swift と C# を同じ枠組みで検証する。

| 段階 | 内容 | 状態 |
|---|---|---|
| 0 | 机上の調査（ダウンロードなし） | **完了**（この文書の 1 章） |
| 1 | Swift: hello、wcount 相当、mandel 相当を作り、4 つの実行環境とブラウザで動かす。Embedded Swift まで試す | **完了**（2 章）。通常版も Embedded 版も、4 つの実行環境とブラウザで動いた |
| 2 | C#: まず B（componentize-dotnet）。A（ブラウザ向け）はあとで | **B は完了**（3 章）。WASI 0.2 のコンポーネントができ、Wasmtime で動いた（ネイティブと同じ速さ）。wazero、Node.js、Deno では動かない。**A（.NET 10）も完了**（5 章）。AOT 版は最適化の後にネイティブと同じ速さ、インタープリター版は約 5 倍遅い。**A（.NET 11）も完了**（6 章）。Mono は .NET 10 とほぼ同じ。CoreCLR はインタープリターだけで、Mono のインタープリター版の約 4.5〜5 倍遅い |

---

## 用語

| 名前 | 指すもの |
|---|---|
| **Swift SDK for WebAssembly** | swift.org が配布する、Swift から Wasm を作るための SDK。1 つの配布物に、通常版（`swift-<版>_wasm`）と Embedded Swift 版（`swift-<版>_wasm-embedded`）の 2 つの SDK が入っている |
| **Embedded Swift** | Swift の機能を絞った実験的なモード。ランタイムをほぼ持たないので、出力がとても小さくなる。使えない機能がある（ARC 以外のランタイムの機能、リフレクション、`Codable` など） |
| **swiftly** | Swift のツールチェーンを入れ替えるためのツール |
| **componentize-dotnet** | C# から WASI 0.2 のコンポーネントを作るツール一式（Bytecode Alliance）。NativeAOT-LLVM、wit-bindgen、wasm-tools、WASI SDK をまとめた NuGet パッケージ |
| **NativeAOT-LLVM** | .NET の Native AOT を Wasm 向けにした実験版（`dotnet/runtimelab`）。componentize-dotnet が中で使う |
| **ビルド用コンテナ（C#）** | componentize-dotnet でビルドするための Linux の Docker コンテナ。macOS では使えないため（1-2） |
| **ビルド用コンテナ（.NET ブラウザ）** | 段階 2-A で使う予定の Linux の Docker コンテナ。.NET 10 SDK にブラウザ向けのワークロードを入れたもの（4 章）。ビルド用コンテナ（C#）とは別 |
| **ワークロード** | .NET の SDK に後から足す追加の道具一式。`wasm-experimental`（ブラウザ向けのテンプレート）と `wasm-tools`（AOT コンパイルに使う Emscripten など）を使う |
| **インタープリター版 / AOT 版** | ブラウザ向けの .NET の 2 つの動かし方。インタープリター版は C# を IL のまま配り、Wasm 化した Mono が解釈して実行する（既定）。AOT 版は C# を前もって Wasm にコンパイルする（`RunAOTCompilation`） |

---

## 1. 段階 0: 机上の調査の結果

### 1-1. Swift

| 項目 | 内容 |
|---|---|
| 最新の版 | **Swift 6.4.2** |
| 必要なもの | swiftly、オープンソース版のツールチェーン 6.4.2、Swift SDK for WebAssembly 6.4.2 |
| Xcode の Swift | **使えない**。Apple のビルドの LLVM に Wasm のバックエンドが入っていないため。Xcode が入っていても上の 3 つは必要（swift.org の手順に明記） |
| 版の一致 | SDK はツールチェーンと**版が完全に一致**している必要がある |
| SDK の ID | 通常版 `swift-6.4.2-RELEASE_wasm`、Embedded 版 `swift-6.4.2-RELEASE_wasm-embedded` |
| ビルド | `swift build --swift-sdk swift-6.4.2-RELEASE_wasm`（Embedded は `..._wasm-embedded`） |
| 実行 | `swift run` は WasmKit（Swift 製の Wasm の実行環境）に任せられる。この検証では、できた `.wasm` を 4 つの実行環境とブラウザで動かす |
| 作れるもの | WASI 0.1 のコアモジュールの見込み（ターゲットの名前は資料で確かめきれていない。ビルド後に `wasm-tools` で確かめる） |

導入の手順（swift.org の手順のとおり。ホストに入れる）:

```sh
# swiftly を入れる（https://www.swift.org/install/macos/ の手順）
swiftly install 6.4.2
swiftly use 6.4.2
swift sdk install \
  https://download.swift.org/swift-6.4.2-release/wasm-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum 83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5
swift sdk list    # swift-6.4.2-RELEASE_wasm と ..._wasm-embedded が出ること
```

注意: swiftly で入れたツールチェーンを使っている間は、`swift` が Xcode のものから切り替わる。Xcode の Swift に戻すときは `swiftly use xcode`（未確認。swiftly の資料で確かめる）。

### 1-2. C#（B: componentize-dotnet）

| 項目 | 内容 |
|---|---|
| 最新の版 | `BytecodeAlliance.Componentize.DotNet.Wasm.SDK` **0.8.0-preview00011**（2026-06-12）。名前のとおりプレビュー版 |
| .NET の SDK | .NET 10 以降 |
| 中で使う NativeAOT-LLVM | `Microsoft.DotNet.ILCompiler.LLVM` 10.0.0-rc.1.26306.1（`dotnet-experimental` という実験用のパッケージの置き場から取得する） |
| 動く OS | NativeAOT-LLVM のパッケージがあるのは **Linux（x64、arm64）と Windows（x64）だけ**。**macOS 向けはない**（パッケージの置き場で確認） |
| この Mac での進め方 | **arm64 の Linux コンテナ**の中でビルドする。arm64 版のパッケージがあるので、x86_64 の模倣は要らない見込み |
| 作れるもの | **WASI 0.2 のコンポーネント**（コアモジュールではない） |
| 動かせる実行環境 | Wasmtime（README では WAMR でも動くとある）。**wazero、Node.js、Deno、ブラウザでは、そのままでは動かない** |
| テンプレート | `componentize.wasi.cli`（CLI アプリ）、`componentize.wasi.lib`（ライブラリのコンポーネント） |
| README にある制約 | 「土台の技術は開発中で、機能が欠けている」。`InvariantGlobalization` と `PublishTrimmed` が必要、など |

コンテナ（ビルド用コンテナ（C#））:

| イメージ | arm64 の大きさ（圧縮時） | 用途 |
|---|---:|---|
| `mcr.microsoft.com/dotnet/sdk:10.0` | **349.9 MB** | componentize-dotnet でのビルド |

ビルドのときにコンテナの中で取得する NuGet のパッケージ:

| パッケージ | 大きさ |
|---|---:|
| `BytecodeAlliance.Componentize.DotNet.Wasm.SDK` 0.8.0-preview00011 | 67.7 MB |
| `BytecodeAlliance.Componentize.DotNet.WitBindgen` 0.8.0-preview00011 | 82.0 MB |
| `Microsoft.DotNet.ILCompiler.LLVM` と `runtime.linux-arm64.…` 10.0.0-rc.1.26306.1 | 不明（LLVM を含むので数百 MB の可能性） |
| テンプレートのパッケージ | 小さい |

NuGet のパッケージは Docker のボリューム（`wasm-csharp-nuget`）に保存し、2 回目以降は取得しないようにする。

### 1-3. .NET の Wasm の最近の状況（参考。A に関係する）

- **.NET 11**（2026 年 11 月ごろ正式版の時期）: ブラウザ向けで、ランタイムを Mono から CoreCLR に移す作業が進んでいる。ただし .NET 11 の時点では試験的な扱いで、**既定は Mono のまま**。CoreCLR はまずインタープリターで動き、完全な対応は .NET 12 の予定という分析がある。
- **WASI**: .NET 本体の WASI 対応は、テストの環境を整えている段階（`dotnet/runtime` の issue）。製品として使える段階ではない。
- A（ブラウザ向け）を進めるときは、.NET 10（LTS）で Mono を使うのが安定。.NET 11 の CoreCLR は「追加で試すもの」として扱う。

---

## 2. 段階 1: Swift（2026-11-12 実施。完了）

ホストの環境: swiftly（Homebrew）、Swift 6.4.2（swift.org のツールチェーン。`~/.swiftly/bin/swift`）、SDK `swift-6.4.2-RELEASE_wasm` と `swift-6.4.2-RELEASE_wasm-embedded`。導入に問題はなかった。swiftly のツールチェーンが既定になっていて、`swift --version` は `Apple Swift version 6.4.2 (swift-6.4.2-RELEASE)` を返す（Xcode の Swift 6.4.2 とは別物）。

### 2-1. 作ったもの

| パッケージ | 対象 Wasm（`dist/`） | 内容 | 使う SDK |
|---|---|---|---|
| `swift/wasi-apps` | `hello-swift.wasm`、`wcount-swift.wasm`、`mandel-swift.wasm` | Go・Rust 版と同じ仕様。mandel は JSON を出す（Go 版にある ppm の出力は省いた） | 通常版 |
| `swift/embedded-mandel` | `mandel-swift-embedded.wasm` | Embedded Swift 版の mandel。条件は 1200×900、最大反復 1000 で固定（引数は使わない）。時刻と出力は WASI の関数を直接呼ぶ | Embedded 版 |

ビルド（それぞれのパッケージのディレクトリで実行）:

```sh
swift build -c release --swift-sdk swift-6.4.2-RELEASE_wasm            # swift/wasi-apps
swift build -c release --swift-sdk swift-6.4.2-RELEASE_wasm-embedded   # swift/embedded-mandel
# 出力: .build/out/Products/Release-webassembly-wasm32/<名前>.wasm
```

ターゲットは `wasm32-unknown-wasip1`（コンパイラの引数で確認）。できるのは **WASI 0.1 のコアモジュール**（先頭が `00 61 73 6d 01 00 00 00`、取り込みは `wasi_snapshot_preview1` だけ）。`wasm-tools validate` は 4 つとも問題なし。

### 2-2. ソースの修正

| ファイル | 問題 | 直したこと |
|---|---|---|
| `wcount/main.swift` | `cannot find type 'FILE' in scope`。wasi-libc では `FILE` が不透明な型で、Swift からは `OpaquePointer` として見える | `CFile` という別名を作り、WASI では `OpaquePointer`、それ以外では `UnsafeMutablePointer<FILE>` にした |
| `mandel-embedded/main.swift` | ビルドは通ったが、`@_extern(wasm, ...)` だけだと **Swift の呼び出し規約**になり、取り込む関数に引数が 2 つ余分に付いた（`clock_time_get` が `(i32 i64 i32 i32 i32)`、`fd_write` が引数 6 つ）。Wasmtime と wazero は `incompatible import type` で読み込みを拒否した。Node.js は終了コード 0 なのに何も出力せず、Deno はたまたま正しく動いた（JS の関数は余分な引数を受け入れるため、型の不一致に気付かない） | `@_extern(c)` を併せて付け、C の呼び出し規約にした。取り込みの型が `(i32 i64 i32)` と `(i32 i32 i32 i32)` になり、4 つとも動いた |

`hello`、`mandel`（通常版）は修正なしで動いた。

### 2-3. 大きさ

| 対象 Wasm | 大きさ | `wasm-tools strip -a` の後 |
|---|---:|---:|
| `hello-swift.wasm` | 7.16 MB | 5.55 MB |
| `wcount-swift.wasm` | 7.85 MB | 6.02 MB |
| `mandel-swift.wasm` | 7.81 MB | 5.98 MB |
| **`mandel-swift-embedded.wasm`** | **67.2 KB** | **20.3 KB** |

ほかの言語との比較（`runtimes.md` の 10 章）:

| mandel | 大きさ |
|---|---:|
| 標準の Go | 4.5 MB |
| TinyGo（`-opt=2 -no-debug`） | 1.36 MB |
| Swift（通常版） | 7.81 MB（strip 後 5.98 MB） |
| **Embedded Swift** | **67.2 KB（strip 後 20.3 KB）** |
| 参考: Rust の wcount | 71.8 KB |
| 参考: 手書きの計算ループ（WAT） | 273 バイト |

- 通常版の Swift は、Swift のランタイムと標準ライブラリ（Unicode の表など）が入るので、Go より大きい。hello でも 7 MB ある。
- Embedded Swift は 2 けた以上小さくなった（7.81 MB → 67.2 KB）。取り込む WASI の関数も 17 個から 10 個に減った。

### 2-4. 4 つの実行環境での動作

| 確認 | Wasmtime（コンテナ） | wazero（コンテナ） | Node.js | Deno |
|---|---|---|---|---|
| `hello-swift.wasm a b` | `hello from Swift (wasi)` / `args: [a b]` | 同じ | 同じ | 同じ |
| `wcount-swift.wasm /data/sample.txt` | `4 12 134 /data/sample.txt`（`wc` と一致） | 同じ | 同じ | 同じ |
| `wcount-swift.wasm`（標準入力 `hello wasm`） | `1 2 11 -` | 同じ | 同じ | 同じ |
| `wcount-swift.wasm /data/none.txt` | `wcount: /data/none.txt: No such file or directory`、終了コード 1 | 同じ | 同じ | 同じ |
| `mandel-swift.wasm 300 225 200` | checksum 2980779 | 同じ | 同じ | 同じ |
| `mandel-swift.wasm 1200 900 1000` | checksum 218222850 | 同じ | 同じ | 同じ |
| `mandel-swift-embedded.wasm` | checksum 218222850 | 同じ | 同じ | 同じ |

Rust 版との違いは、ファイルがないときのメッセージだけ（Rust は末尾に `(os error 44)` が付く）。

### 2-5. ブラウザでの動作

任意の Wasm を 1 回実行する汎用のページ `web/run.html`（`?wasm=` と `?args=` で指定）と、それをヘッドレスの Chrome で動かす `bench/run-browser.mjs` を足した（`index.html` と `bench-browser.mjs` はそのまま）。

```sh
python3 -m http.server 8765 --bind 127.0.0.1     # 別の端末で
node bench/run-browser.mjs ../dist/mandel-swift.wasm 1200,900,1000
```

| 対象 Wasm | 結果（Chrome 157、ヘッドレス） | コンパイル |
|---|---|---:|
| `hello-swift.wasm a b` | `hello from Swift (wasi)` / `args: [a b]`、終了コード 0 | 37 ms |
| `mandel-swift.wasm 300 225 200` | checksum 2980779 | 54 ms |
| `mandel-swift.wasm 1200 900 1000` | checksum 218222850、計算 937.8 ms | 49 ms |
| `mandel-swift-embedded.wasm` | checksum 218222850、計算 659.9 ms | 9 ms |

ブラウザ用の WASI（`web/wasi-shim.js`）には追加が要らなかった。Swift の Wasm が取り込む関数のうち、shim にないもの（`fd_read`、`fd_seek`、`path_open`、`poll_oneoff`）は「未実装」を返すが、hello と mandel では呼ばれなかった。ブラウザでは 1 回だけ実行しているので、計算時間は V8 の最初の遅いコード（Liftoff）のもの。

### 2-6. 速さ

条件: 1200×900、最大反復 1000、各 5 回の中央値。ネイティブ比は `runtimes.md` 10-2 の Go ネイティブ（386.2 ms）を基準にした。checksum はすべて 218222850。

| 実装 | 計算時間 (ms) | ネイティブ比 | 全体の時間 (ms) |
|---|---:|---:|---:|
| Swift → Wasm on Node.js | 921.7 | 2.39 | 973.8 |
| Swift → Wasm on Node.js（`--no-liftoff`） | 388.3 | 1.01 | 614.6 |
| Swift → Wasm on Wasmtime（コンテナ） | 382.7 | **0.99** | 1540.3 |
| Swift → Wasm on wazero（コンテナ） | 398.8 | 1.03 | 1629.9 |
| Swift → Wasm on ホストの Wasmtime（参考） | 379.9 | 0.98 | 418.8 |
| Embedded Swift → Wasm on Node.js | 647.1 | 1.68 | 687.5 |
| Embedded Swift → Wasm on Node.js（`--no-liftoff`） | 381.1 | 0.99 | 432.1 |
| Embedded Swift → Wasm on Wasmtime（コンテナ） | 383.2 | **0.99** | 575.7 |
| Embedded Swift → Wasm on wazero（コンテナ） | 395.9 | 1.03 | 573.2 |
| Embedded Swift → Wasm on ホストの Wasmtime（参考） | 379.4 | 0.98 | 383.0 |

参考（`runtimes.md` 10-2）: Wasmtime（コンテナ）では、標準の Go が 1.96 倍、TinyGo が 2.04 倍だった。

### 2-7. 分かったこと

- **Swift の Wasm は、4 つの実行環境とブラウザでそのまま動いた**: WASI 0.1 のコアモジュールなので、Go・Rust と同じ枠組みに乗った。ファイル、標準入出力、引数、終了コードのどれも差がなかった。
- **Wasmtime でもネイティブと同じ速さだった**: 標準の Go や TinyGo では約 2 倍かかった Wasmtime（`runtimes.md` 10-4）で、Swift は 0.99 倍だった。Swift のコンパイラが計算の関数を大きな関数にまとめなかったためとみられる（10-4 の結論と合う。機械語は確かめていない）。
- **Embedded Swift は小さく、起動も速い**: 67 KB で、全体の時間（起動とコンパイルを含む）も短い（Node.js で 974 ms → 688 ms、Wasmtime のコンテナで 1,540 ms → 576 ms）。V8 の最初の遅いコードでの計算も、通常版（2.39 倍）より速い（1.68 倍）。
- **Embedded Swift は書き方の制約が大きい**: 文字列や浮動小数点数の文字列化に頼らず、数字を自分で ASCII にした。外の関数を呼ぶときは `@_extern(wasm, ...)` と `@_extern(c)` の両方が要る。片方だけだと、ビルドは通るのに実行環境によって動いたり動かなかったりするので、気付きにくい。
- **JS の実行環境は、取り込む関数の型の不一致に気付かない**: Node.js と Deno は、型の合わない取り込みでもそのまま読み込んだ（Deno は動き、Node.js は出力なしで終わった）。Wasmtime と wazero は読み込みの時点で拒否した。型の確認には Wasmtime か wazero を使う方が確実。

### 2-8. 確かめていないこと

- 通常版の Swift の大きさの内訳（どの部分が大きいか）
- Swift の Wasm が Wasmtime で速い理由を、機械語で確かめること
- `swiftly use xcode` で Xcode の Swift に戻せるか（1-1 の注意）
- `bench/bench-cli.mjs` への Swift の行の追加（今回は使い捨てのスクリプトで計った）

---

## 3. 段階 2: C#（B: componentize-dotnet）

**状態: 完了（2026-11-12）**。C# の mandel を WASI 0.2 のコンポーネント（2.9 MB）にでき、Wasmtime（ホストとコンテナ）で checksum が一致した。**計算時間は約 382 ms で、ネイティブ（386 ms）と同じ水準**（Go・TinyGo の Wasm は Wasmtime で約 2 倍だった）。wazero、Node.js、Deno では、コンポーネントなので読み込めない。

### 3-1. 用意したもの

| もの | 内容 |
|---|---|
| `csharp/Dockerfile` | ビルド用コンテナ（C#）。`dotnet/sdk:10.0`（arm64）に componentize-dotnet のテンプレート 0.8.0-preview00011 と、arm64 向けの WASI SDK 29.0 を入れる。イメージは 1.9 GB |
| `csharp/build.sh` | コンテナの中で、テンプレートからプロジェクトを作り、`Program.cs` を差し替えてビルドし、`/out` にコピーする |
| `csharp/mandel/Program.cs` | mandel の C# 版 |

テンプレート（`componentize.wasi.cli`）が作る csproj には、README にある設定（`RuntimeIdentifier=wasi-wasm`、`PublishTrimmed`、`InvariantGlobalization`、`SelfContained`）と、`dotnet-experimental` の置き場を指す `nuget.config` が最初から入っていた。`dotnet build` のあとに `Publish` が自動で走る（SDK の targets にある `PublishAfterBuild`）。

### 3-2. ビルドで起きたこと

| # | 起きたこと | 対応 |
|---|---|---|
| 1 | `error : Add a PackageReference for 'runtime.linux-arm64.Microsoft.DotNet.ILCompiler.LLVM' to allow cross-compilation for wasm`。テンプレートの csproj が x64 の Linux 向けの NativeAOT-LLVM（`runtime.linux-x64.…`）を固定で参照しているため | `build.sh` で、コンテナの CPU に合わせて `runtime.linux-arm64.…` に書き換えるようにした → この段階は通った（C# → LLVM のビットコードまでできた） |
| 2 | WASI SDK の clang を動かすところで、`rosetta error : failed to open elf at /lib64/ld-linux-x86-64.so.2`（34 個のエラー）。componentize-dotnet の WitBindgen のパッケージが、Linux では**常に x86_64 向けの WASI SDK**（`wasi-sdk-29.0-x86_64-linux.tar.gz`）を取得するため（`BytecodeAlliance.Componentize.DotNet.WitBindgen.targets` の `WasiSdkUrl`。CPU を見ていない） | `Dockerfile` で、イメージを作るときに **arm64 向けの WASI SDK 29.0** を `/root/.wasi-sdk/wasi-sdk-29.0`（targets の `WasiSdkRoot`）に展開しておくようにした。targets はこの場所があれば取得しない（`Condition="!(Exists($(WasiSdkRoot)))"`）ので、x86_64 版は取得されなくなり、ビルドが通った |

ビルドの時間: 失敗した 2 回が約 25 秒（NuGet の取得を含む）と約 18 秒。**成功したビルドは約 6 秒**（`dotnet build` の表示で 4.55 秒。NuGet と WASI SDK はすでにあるため）。

**ビルドの手順**（`wasm/` で実行）:

```sh
docker build -t wasm-csharp-build:local csharp
docker run --rm -v "$PWD/csharp/mandel:/src:ro" -v "$PWD/dist:/out" \
  -v wasm-csharp-nuget:/root/.nuget wasm-csharp-build:local
# → dist/mandel-csharp.wasm
```

**取得したもの**:

| もの | 大きさ |
|---|---:|
| `mcr.microsoft.com/dotnet/sdk:10.0`（arm64） | 349.9 MB（圧縮時） |
| arm64 向けの WASI SDK 29.0（イメージに入れた） | 119.3 MB（ビルド用コンテナのイメージは全体で 1.9 GB） |
| NuGet のパッケージ（ボリューム `wasm-csharp-nuget`） | 784 MB（使わない x64 向けの NativeAOT-LLVM を含む） |
| x86_64 向けの WASI SDK（失敗したビルドの中で 1 回だけ） | 119.4 MB（使えなかった。コンテナと一緒に消えている） |

### 3-3. できた Wasm

| 項目 | 内容 |
|---|---|
| ファイル | `dist/mandel-csharp.wasm` |
| 大きさ | **2.9 MB**（2,925,400 バイト） |
| 形式 | **WASI 0.2 のコンポーネント**（先頭の 8 バイトが `00 61 73 6d 0d 00 01 00`。コアモジュールは `01 00 00 00`）。`wasm-tools validate` で問題なし |
| export | `wasi:cli/run@0.2.6`（CLI のコマンドとして動く形） |
| import | `wasi:cli/*`（環境変数、終了、標準入出力、端末）、`wasi:clocks/*`（単調時刻、実時刻）、`wasi:io/*`、`wasi:filesystem/*`、`wasi:random/random`（すべて 0.2.6） |
| 引数 | `args[0]` が最初の引数（プログラム名は入らない）。`Program.cs` の書き方のままで正しく動いた |

### 3-4. 実行環境ごとの結果

| 実行環境 | 結果 | 出力・エラー |
|---|---|---|
| Wasmtime（ホスト、50.0.1） | **動いた** | `300 225 200` で checksum 2980779、`1200 900 1000` と引数なしで 218222850。終了コード 0 |
| Wasmtime（コンテナ） | **動いた** | 同じ |
| wazero（コンテナ） | 動かない | `error compiling wasm binary: invalid version header`（終了コード 1） |
| Node.js | 動かない | `CompileError: WebAssembly.compile(): expected version 01 00 00 00, found 0d 00 01 00 @+4` |
| Deno | 動かない | `CompileError: WebAssembly.compile(): expected version 01 00 00 00, found 0d 00 01 00 @+4` |

wazero、Node.js、Deno は、どれもファイルの先頭の版番号（コンポーネントの `0d 00 01 00`）の時点で読み込みを拒否した。Node.js と Deno で動かすには、jco でコンポーネントを JS とコアモジュールに変換する必要がある（今回はやっていない）。

### 3-5. 速さ

条件: 1200×900、最大反復 1000、5 回の中央値。checksum はすべて 218222850。

| 実装 | 計算時間 中央値 (ms) | 計算時間 最小 (ms) | 全体の時間 中央値 (ms) |
|---|---:|---:|---:|
| **C# → Wasm on ホストの Wasmtime** | **381.9** | 381.5 | 397.3 |
| **C# → Wasm on Wasmtime（コンテナ）** | **382.2** | 381.6 | 724.7 |
| 参考: Go ネイティブ（同じ時に計測） | 386.3 | 386.0 | 388.9 |
| 参考: Go → Wasm on Wasmtime（コンテナ）（`runtimes.md` 10-2） | 755.7 | — | 1366.4 |
| 参考: TinyGo → Wasm on Wasmtime（コンテナ）（同上） | 787.2 | — | 1248.6 |

- **C# の Wasm は、Wasmtime でネイティブと同じ速さ**だった。同じ Wasmtime で約 2 倍かかった Go・TinyGo の Wasm より、約 2 倍速い。
- 全体の時間も短い。ホストでは 397 ms で、計算以外（起動と 2.9 MB のコンパイル）は約 15 ms。コンテナでは、起動の分（約 0.3 秒）が上乗せされる。

### 3-6. 分かったこと

- **componentize-dotnet は arm64 の Linux で使えた**。ただし、そのままでは 2 か所で x64 前提になっていて、手直しが要った（テンプレートの NativeAOT-LLVM の参照と、WASI SDK の取得先）。どちらも 0.8.0-preview00011 の時点の問題。macOS では、NativeAOT-LLVM のパッケージ自体がないので使えない。
- **C# の Wasm が Wasmtime で速い理由（推測）**: `runtimes.md` の 10-4 では、計算のループが大きな関数の中にあると、Wasmtime のコンパイラがループの変数をレジスタに置ききれず遅くなることが分かった。NativeAOT-LLVM は `Mandelbrot` を独立した関数のまま出力し、goroutine のような仕組みも入らないので、ループが小さな関数の中に収まり、その問題を避けられているとみられる（機械語は確かめていない）。
- **できるのはコンポーネントだけ**なので、今回の 4 つの実行環境のうち動くのは Wasmtime だけ。4 つ全部とブラウザで比べる枠組みには乗らない。ほかの実行環境で動かすなら、jco での変換（Node.js、Deno、ブラウザ）か、A（ブラウザ向けの .NET）を使う。

### 3-7. まだやっていないこと

- A（ブラウザ向けの .NET。インタープリターと AOT の比較）
- jco でコンポーネントを変換して、Node.js、Deno、ブラウザで動かすこと
- C# の Wasm の機械語を見て、速い理由を確かめること
- `bench/bench-cli.mjs` への C# の行の追加（Swift の作業と同時に動いていたため、触っていない）

---

## 4. 段階 2-A: ブラウザ向けの .NET（計画。結果は 5 章）

### 4-1. 目的

- C# の計算部品（mandel）をブラウザで動かし、**インタープリター版と AOT 版**で速さを比べる
- 同じブラウザ（ヘッドレスの Chrome）で動かした Go・TinyGo・Swift・JS と、大きさ・起動の速さ・計算の速さを並べる
- `wasm.md` の 2 章で整理した「Blazor は既定では C# を Wasm に変換しない」ことを、実際の数字で確かめる

### 4-2. 仕組み（B との違い）

| | B（componentize-dotnet） | A（ブラウザ向けの .NET） |
|---|---|---|
| 作るもの | WASI 0.2 のコンポーネント（1 ファイル） | `dotnet.js`（起動用の JS）、`dotnet.native.wasm`（Wasm 化した Mono ランタイム）、アプリの DLL（Wasm の形式に包んだもの）などのファイル一式 |
| 動く場所 | Wasmtime | ブラウザ（`wasmconsole` テンプレートなら Node.js も） |
| C# の呼び出し方 | WASI のコマンド（`_start`） | JS から `[JSExport]` を付けた C# のメソッドを呼ぶ（計算部品型。`runtimes.md` の 0-3） |
| 状態 | 実験版 | 正式な仕組み（ただしテンプレートは「実験的」の扱い） |

`runtimes.md` の `web/wasi-shim.js` では動かせない（WASI ではなく、.NET 独自の JS のつなぎのコードを使うため）。

### 4-3. 調べたこと（2026-11-12）

| 項目 | 内容 |
|---|---|
| テンプレート | `wasmbrowser`（ブラウザ）と `wasmconsole`（Node.js）。`wasm-experimental` ワークロードか、`Microsoft.NET.Runtime.WebAssembly.Templates.net10`（最新 10.0.15）で入る |
| AOT に要るもの | `wasm-tools` ワークロード（Emscripten 3.1.56 など）。AOT は `dotnet publish` のときだけ行われる |
| arm64 の Linux への対応 | **ある**。Emscripten の SDK のパッケージに `linux-arm64` 版がある（`osx-arm64` 版もあるので、ホストに .NET を入れる方法も取れる） |
| 既知の問題（未確認） | .NET 10 で、JS から `[JSExport]` を呼ぶと `createDotNetRuntime is not defined` になったという利用者の報告がある（2026 年 2 月。公式の回答ではない） |
| ランタイム | .NET 10 では Mono。.NET 11 では CoreCLR が試験的に使えるが既定は Mono（1-3） |

### 4-4. 進め方の案

**ビルドする場所**: 手元にある `mcr.microsoft.com/dotnet/sdk:10.0`（arm64）をもとに、ワークロードを入れたビルド用コンテナ（.NET ブラウザ）を作る。ホストに .NET を入れない（B と同じ方針）。

| # | 手順 | 確かめること |
|---|---|---|
| 1 | ビルド用コンテナ（.NET ブラウザ）を作る（`wasm-experimental` と `wasm-tools` を入れる） | ワークロードが arm64 で入ること |
| 2 | `dotnet new wasmbrowser` でプロジェクトを作り、mandel を `[JSExport]` のメソッドとして書く（戻り値は checksum。時間は JS 側で計る） | ビルドが通ること |
| 3 | インタープリター版を `dotnet publish` で作る | checksum が 218222850 になること |
| 4 | AOT 版を `-p:RunAOTCompilation=true` で作る | 同上。publish にかかる時間 |
| 5 | `python3 -m http.server` で配信し、ヘッドレスの Chrome で動かす（`bench/bench-browser.mjs` と同じ方法で、終わったら `document.title` を DONE にする） | 起動の時間（ランタイムの読み込み）、1 回目と 2 回目以降の計算時間 |
| 6 | 配るファイルの合計の大きさを計る（圧縮前と、Brotli・gzip の圧縮後） | インタープリター版と AOT 版の差 |
| 7 | 同じブラウザで動かした Go・TinyGo・Swift・JS と表にまとめる | — |

計る値（各 5 回の中央値）:

| 値 | 内容 |
|---|---|
| 起動の時間 | ページを開いてから、.NET のランタイムが使えるようになるまで |
| 計算時間（1 回目） | 最初の呼び出し。V8 の Liftoff の影響を受ける |
| 計算時間（2 回目以降） | 最適化の後 |
| 配るファイルの大きさ | `_framework/` の合計 |

**後回しにするもの**: `wasmconsole` で Node.js で動かすこと、.NET 11 の CoreCLR で試すこと、Blazor のアプリとして作ること。

### 4-5. 必要な取得（コンテナの中）

| もの | 大きさ |
|---|---:|
| `mcr.microsoft.com/dotnet/sdk:10.0`（arm64） | 取得済み（B で使ったもの） |
| Emscripten の SDK（`Microsoft.NET.Runtime.Emscripten.3.1.56.Sdk.linux-arm64`） | 136.1 MB |
| Emscripten のキャッシュ（`…Cache.linux-arm64`） | 67.2 MB |
| Emscripten 用の Node.js（`…Node.linux-arm64`） | 24.1 MB |
| ブラウザ向けの Mono ランタイム（`Microsoft.NETCore.App.Runtime.Mono.browser-wasm`） | 24.6 MB |
| AOT のクロスコンパイラ（`…AOT.linux-arm64.Cross.browser-wasm`） | 7.1 MB |
| WebAssembly の SDK（`Microsoft.NET.Runtime.WebAssembly.Sdk`） | 4.6 MB |
| テンプレート、AOT のタスクなど | 小さい |
| **合計** | **約 265 MB**（版は 10.0.15 で計算。実際に入る版はイメージの SDK の版による） |

### 4-6. 決めること

1. 上の取得（約 265 MB）を行ってよいか
2. Node.js（`wasmconsole`）での計測も今回やるか
3. .NET 11 の CoreCLR を試すか（後回しの案）

（2026-11-12 に 1・2 は「はい」で実施。結果は 5 章。3 の .NET 11 は別に承認を取ってから行う）

---

## 5. 段階 2-A の結果（.NET 10）（2026-11-12 実施）

### 5-1. 作ったもの

| もの | 内容 |
|---|---|
| `csharp-browser/Dockerfile` | ビルド用コンテナ（.NET ブラウザ）。`dotnet/sdk:10.0` に `wasm-tools` と `wasm-experimental` を入れ、Python 3 を足したもの |
| `csharp-browser/build.sh` | 2 つのプロジェクト × 2 つの方式（インタープリター版、AOT 版）を publish して `dist/` に置く |
| `csharp-browser/browser/` | `wasmbrowser` テンプレートから作ったブラウザ版。`Program.cs` に `[JSExport]` の `Mandel.Run(w, h, maxIter)`（戻り値は checksum）、`wwwroot/main.js` で起動の時間と計算時間を計る |
| `csharp-browser/console/` | `wasmconsole` テンプレートから作った Node.js 版。計算は同じ。`main.mjs` で計る |
| `bench/bench-dotnet-browser.mjs` | ブラウザ版をヘッドレスの Chrome で計る。毎回新しいプロファイルで Chrome を起動する（コンパイル結果のキャッシュを使わない「初回の読み込み」を計るため） |
| `dist/dotnet-{browser,console}-{interp,aot}/` | publish の出力 |

```sh
docker build -t wasm-dotnet-browser:local csharp-browser
docker run --rm -v "$PWD/csharp-browser:/src:ro" -v "$PWD/dist:/out" \
  -v wasm-dotnet-browser-nuget:/root/.nuget wasm-dotnet-browser:local sh /src/build.sh
node dist/dotnet-console-aot/main.mjs 1200 900 1000 5          # Node.js
python3 -m http.server 8765 --bind 127.0.0.1                   # 別の端末で
node bench/bench-dotnet-browser.mjs 5 "calls=5"                # ブラウザ
```

### 5-2. ビルドで起きたこと

| 起きたこと | 対応 |
|---|---|
| Release の publish で `unable to find python in $PATH` になり、Mono ランタイムの C のファイルのコンパイルが止まった。Linux 向けの Emscripten のパッケージには Python が入っていない（macOS / Windows 向けにはある） | イメージに `python3` を apt で足した（数十 MB 未満の取得。承認の範囲の 265 MB には入っていなかった） |
| console 版の `dotnet publish -o` の出力に、ビルドの途中のファイル（`.a`、`.c` など）が混ざり、`main.mjs` がなかった | 実行用にまとめられた `bin/Release/net10.0/browser-wasm/AppBundle` を使うようにした |
| Node.js で、インタープリター版のときに `MONO_WASM: Error loading symbol file dotnet.native.js.symbols: {}` が標準出力に出た | 計算には影響しない（デバッグ用の情報ファイルの読み込みの失敗）。集計では JSON の行だけを使った |

心配していた .NET 10 の既知の問題（`createDotNetRuntime is not defined`）は、ブラウザでも Node.js でも出なかった。

| 項目 | 値 |
|---|---|
| ビルド用コンテナ（.NET ブラウザ）の大きさ | 3.17 GB（ワークロードを入れた時点で 3.11 GB。Python を足して 3.17 GB） |
| ワークロード | `wasm-tools`、`wasm-experimental` とも 10.0.115/10.0.100（SDK 10.0.400 の帯域。ワークロードの版 10.0.404）。パックは 10.0.15 |
| publish の時間 | ブラウザ版: インタープリター 11 秒、AOT 29 秒。console 版: インタープリター 6 秒、AOT 17 秒 |

### 5-3. 大きさ（`_framework/` の合計）

| 方式 | 合計（圧縮前） | gzip（-9） | Brotli（publish が作ったもの） | うち `dotnet.native.wasm` |
|---|---:|---:|---:|---:|
| インタープリター版 | 7.09 MB | 2.52 MB | 2.01 MB | 2.88 MB |
| AOT 版 | 11.29 MB | 3.65 MB | 2.75 MB | 7.07 MB |

- どちらも、ランタイム（`dotnet.native.wasm`）、`System.Private.CoreLib`（1.1 MB）、文字コードなどのデータ（ICU、約 2 MB）が大きい。
- AOT 版では、C# のコードが Wasm にコンパイルされて `dotnet.native.wasm` に入るので、その分大きくなる（+4.2 MB）。
- console 版もほぼ同じ大きさ（インタープリター版 7.09 MB、AOT 版 11.27 MB）。

### 5-4. ブラウザ（ヘッドレスの Chrome 157。各 5 回の中央値）

1200×900、最大反復 1000。1 回の読み込みで 5 回呼び、1 回目と 2〜5 回目を分けた。checksum はすべて 218222850（300×225×200 では 2980779）で一致した。

| 方式 | ランタイムが使えるまで（ページの読み込み開始から） | うち .NET の初期化 | 計算 1 回目 | 計算 2 回目以降 |
|---|---:|---:|---:|---:|
| インタープリター版 | 84.4 ms | 64.9 ms | 1,862.3 ms | 1,909.3 ms |
| AOT 版 | 93.2 ms | 76.9 ms | 939.7 ms | **387.5 ms** |

### 5-5. Node.js（v26.13.0。各 5 回の中央値）

| 方式 | ランタイムが使えるまで（プロセスの開始から） | うち .NET の初期化 | 計算 1 回目 | 計算 2 回目以降 |
|---|---:|---:|---:|---:|
| インタープリター版 | 56.3 ms | 46.4 ms | 1,853.4 ms | 1,960.6 ms |
| AOT 版 | 54.4 ms | 43.7 ms | 928.6 ms | **386.5 ms** |
| AOT 版（`--no-liftoff`、1 回だけ） | 469.3 ms | 457.8 ms | 386.6 ms | 386.1 ms |

### 5-6. ほかの言語との比較（ブラウザ、ヘッドレスの Chrome 157）

| 実装 | 計算 1 回目（Liftoff） | 最適化の後 | 配る大きさ（圧縮前） | 出典 |
|---|---:|---:|---:|---|
| C#（.NET 10、インタープリター版） | 1,862 ms | 1,909 ms（最適化の対象にならない） | 7.09 MB | この章 |
| C#（.NET 10、AOT 版） | 940 ms | 388 ms | 11.29 MB | この章 |
| Go → Wasm | — | 386.7 ms | 4.5 MB | `runtimes.md` 9-3（画像の計算の後に計ったので最適化の後） |
| JS | — | 393.5 ms | — | `runtimes.md` 9-3 |
| Swift | 938 ms | 未計測 | 7.8 MB | 2-5（1 回だけの実行） |
| Embedded Swift | 660 ms | 未計測 | 67 KB | 2-5（1 回だけの実行） |

参考: Go ネイティブは約 386 ms。

### 5-7. 分かったこと

- **AOT 版は、最適化の後はネイティブと同じ速さ**（ブラウザ 387.5 ms、Node.js 386.5 ms）。1 回目は V8 の Liftoff のコードで動くので約 2.4 倍かかる（`runtimes.md` 9-4 と同じ現象）。
- **インタープリター版は約 4.8〜5 倍遅く、呼び出しを重ねても速くならない**。C# の IL を Mono のインタープリターが解釈して実行するので、V8 の最適化が C# のコードには効かない（インタープリター自体は最適化されても、解釈の手間は残る）。`wasm.md` の 2 章で整理した「Blazor は既定では C# を Wasm に変換しない」ことが、速さの差として出た。
- **起動はどちらも速い**（ブラウザでランタイムが使えるまで 85〜95 ms、Node.js で 55 ms 前後）。AOT 版は `dotnet.native.wasm` が大きい分、わずかに遅い。`--no-liftoff` を付けると 7 MB の Wasm を最初に最適化するので、初期化が 458 ms に増える。
- **大きさは AOT 版の方が 1.6 倍**（7.09 MB → 11.29 MB。Brotli では 2.01 MB → 2.75 MB）。重い計算をする部品なら AOT 版、起動と配信の軽さを優先する画面の処理ならインタープリター版、という使い分けになる。
- **B（componentize-dotnet）との違い**: B は Wasmtime 用のコンポーネント 1 ファイル（2.9 MB）、A は JS のつなぎのコードとランタイム一式（7〜11 MB）。速さ（最適化の後）はどちらもネイティブと同じ水準。
- **Linux のコンテナでの注意**: Emscripten が Python を要求する。.NET の SDK のイメージには Python が入っていないので、足す必要がある。

### 5-8. 確かめていないこと

- インタープリター版が 2 回目以降にわずかに遅くなる（1,862 → 1,909 ms）理由
- AOT 版の機械語（Wasmtime の問題（`perf-open-questions.md` の Q1・Q2）とは別の実行環境なので、今回は見ていない）
- ICU のデータを外す設定（`InvariantGlobalization`）や不要な機能の削除で、どこまで小さくなるか
- 2 回目の読み込み（ブラウザのキャッシュが効く場合）の起動の時間
- `perf-open-questions.md` との関係: Q5（Liftoff での遅さの言語ごとの違い）に、C#（AOT 版）の 1 回目 約 2.4 倍（940 ms）という値が加わる。Q11（ブラウザの種類）は今回も Chrome だけ

---

## 6. 段階 2-A の結果（.NET 11、Mono と CoreCLR）（2026-11-13 実施）

5 章と同じソース（`csharp-browser/browser/`）を net11.0 に書き換えて、.NET 11 の Mono（インタープリター版、AOT 版）と CoreCLR を比べた。計り方も 5 章と同じ（1200×900、最大反復 1000、各 5 回の中央値。1 回の読み込みで 5 回呼び、1 回目と 2〜5 回目を分ける）。

### 6-1. 作ったもの

| もの | 内容 |
|---|---|
| `csharp-browser/Dockerfile.net11` | ビルド用コンテナ（.NET ブラウザ、.NET 11）。`dotnet/sdk:11.0` に `wasm-tools` と `wasm-experimental` を入れ、Python 3 を足したもの。イメージは `wasm-dotnet-browser:net11` |
| `csharp-browser/build-net11.sh` | ブラウザ版を 4 つの方式で publish して `dist/dotnet11-browser-<方式>/` に置く |
| `bench/run-dotnet11-node.mjs` | ブラウザ版の出力を Node.js で直接読み込んで計る（6-3 を参照） |
| `bench/bench-dotnet-browser.mjs` | 計る対象のディレクトリ名を 4 つ目の引数で指定できるようにした（指定しなければ .NET 10 の 2 つを計る。これまでの動きは変えていない） |

```sh
docker build -f csharp-browser/Dockerfile.net11 -t wasm-dotnet-browser:net11 csharp-browser
docker run --rm -v "$PWD/csharp-browser:/src:ro" -v "$PWD/dist:/out" \
  -v wasm-dotnet11-browser-nuget:/root/.nuget wasm-dotnet-browser:net11 sh /src/build-net11.sh
python3 -m http.server 8765 --bind 127.0.0.1    # 別の端末で
node bench/bench-dotnet-browser.mjs 5 "calls=5" "dotnet11-browser-mono-interp,dotnet11-browser-mono-aot,dotnet11-browser-coreclr"
node bench/run-dotnet11-node.mjs dist/dotnet11-browser-coreclr 1200 900 1000 5
```

| 項目 | 値 |
|---|---|
| ビルド用コンテナ（.NET ブラウザ、.NET 11）の大きさ | 3.74 GB（イメージを作るのに 102 秒） |
| .NET の SDK | 11.0.100 |
| ワークロード | `wasm-tools`、`wasm-experimental` とも 11.0.100（ワークロードの版 11.0.100.1）。パックは 11.0.0。Emscripten は 6.0.2 |
| 入ったランタイムのパック | `Microsoft.NETCore.App.Runtime.Mono.browser-wasm`（Mono）、`Microsoft.NETCore.App.Runtime.browser-wasm`（CoreCLR）、`…Mono.multithread.browser-wasm` |
| publish の時間 | Mono インタープリター版 12 秒、Mono AOT 版 30 秒、CoreCLR 10 秒 |

### 6-2. CoreCLR の有効にしかたと制約

| 項目 | 内容 |
|---|---|
| 既定 | **Mono**（`Microsoft.NET.Sdk.WebAssembly` の `Sdk.props` で `UseMonoRuntime` が既定で `true`） |
| CoreCLR にする方法 | **`-p:UseMonoRuntime=false`**。`Microsoft.NET.Runtime.WebAssembly.Sdk` の `Sdk.targets` が、この値で `BrowserWasmApp.targets`（Mono）と `BrowserWasmApp.CoreCLR.targets`（CoreCLR）を切り替える。公式の資料にはブラウザ向けの説明は見つからず、SDK の targets を読んで確かめた |
| 動き方 | **インタープリターだけ**。CoreCLR 用の targets には ReadyToRun（事前コンパイル）や AOT の手順がない |
| AOT の指定 | **無視される**。`-p:RunAOTCompilation=true` を足しても、出力はすべてのファイルが同じだった（`dotnet.native.wasm` の SHA-256 も一致） |
| 必須の条件 | Wasm の例外処理と SIMD を無効にできない（targets にエラーの条件がある） |
| Release の publish | ランタイムの作り直し（Emscripten でのリンク）で失敗する（6-3）。`-p:WasmBuildNative=false` で、配布物のランタイムをそのまま使うと通った |

### 6-3. ビルドで起きたこと

| 起きたこと | 対応 |
|---|---|
| CoreCLR の Release の publish で、リンクが `wasm-ld : error : …libemscripten_js_symbols.so: undefined symbol: SystemJS_ExecuteTimerCallback. Required by SystemJS_ScheduleTimer`（ほか多数）で失敗した | `-p:WasmBuildNative=false` を付けて、ランタイムを作り直さないようにした。.NET 11.0.100 の SDK とワークロードの組み合わせの問題とみられる（原因は調べていない） |
| **.NET 11 には Node.js 用のテンプレート（`wasmconsole`）がない**（`dotnet new list wasm` に出るのは `wasmbrowser`、`blazorwasm` など） | — |
| .NET 10 の console 版の作り（`Microsoft.NET.Sdk` に `RuntimeIdentifier=browser-wasm`）は、.NET 11 では `$(MicrosoftNetCoreAppRuntimePackDir)='', and cannot find %(ResolvedRuntimePack.PackageDirectory)` で失敗した。`-p:UseMonoRuntime=true` を足しても同じ | Node.js では、**ブラウザ版の出力（`wwwroot/_framework/dotnet.<指紋>.js`）を直接 `import` して動かした**（`bench/run-dotnet11-node.mjs`）。Mono も CoreCLR もこれで動いた |

### 6-4. 大きさ（`_framework/` の合計）

| 方式 | 合計（圧縮前） | gzip（-9） | Brotli（publish が作ったもの） | うち `dotnet.native.wasm` |
|---|---:|---:|---:|---:|
| .NET 11 Mono インタープリター版 | 7.55 MB | 2.65 MB | 2.09 MB | 3.01 MB |
| .NET 11 Mono AOT 版 | 12.06 MB | 3.86 MB | 2.87 MB | 7.52 MB |
| .NET 11 CoreCLR | 9.54 MB | 3.38 MB | 2.58 MB | 4.75 MB |
| 参考: .NET 10 Mono インタープリター版 | 7.09 MB | 2.52 MB | 2.01 MB | 2.88 MB |
| 参考: .NET 10 Mono AOT 版 | 11.29 MB | 3.65 MB | 2.75 MB | 7.07 MB |

### 6-5. ブラウザ（ヘッドレスの Chrome 157。各 5 回の中央値）

checksum はすべて 218222850 で一致した。

| 方式 | ランタイムが使えるまで | うち .NET の初期化 | 計算 1 回目 | 計算 2 回目以降 |
|---|---:|---:|---:|---:|
| .NET 11 Mono インタープリター版 | 94.6 ms | 78.3 ms | 1,911 ms | 1,956 ms |
| .NET 11 Mono AOT 版 | 97.3 ms | 78.9 ms | 948 ms | **388 ms** |
| .NET 11 CoreCLR | 126.4 ms | 109.3 ms | **14,339 ms** | **8,641 ms** |
| 参考: .NET 10 Mono インタープリター版 | 84.4 ms | 64.9 ms | 1,862 ms | 1,909 ms |
| 参考: .NET 10 Mono AOT 版 | 93.2 ms | 76.9 ms | 940 ms | 388 ms |

### 6-6. Node.js（v26.13.0。各 5 回の中央値。ブラウザ版の出力を直接読み込む）

| 方式 | ランタイムが使えるまで | うち .NET の初期化 | 計算 1 回目 | 計算 2 回目以降 |
|---|---:|---:|---:|---:|
| .NET 11 Mono インタープリター版 | 57.8 ms | 47.4 ms | 1,928 ms | 1,869 ms |
| .NET 11 Mono AOT 版 | 56.2 ms | 45.6 ms | 949 ms | **387 ms** |
| .NET 11 Mono AOT 版（`--no-liftoff`、1 回だけ） | 485.6 ms | 465.9 ms | 396 ms | 394 ms |
| .NET 11 CoreCLR | 110.1 ms | 97.6 ms | **14,570 ms** | **9,343 ms** |
| 参考: .NET 10 Mono インタープリター版（console 版） | 56.3 ms | 46.4 ms | 1,853 ms | 1,961 ms |
| 参考: .NET 10 Mono AOT 版（console 版） | 54.4 ms | 43.7 ms | 929 ms | 387 ms |

### 6-7. 分かったこと

- **.NET 11 の Mono は、.NET 10 とほぼ同じ**。速さは誤差の範囲で、大きさは 5〜7% 増えた。AOT 版は最適化の後にネイティブ（約 386 ms）と同じ速さ。
- **.NET 11 の CoreCLR（ブラウザ）は、まだ実用の速さではない**。インタープリターだけで動き、計算は 2 回目以降でも約 8.6〜9.3 秒（ネイティブの約 22〜24 倍、Mono のインタープリター版の約 4.5〜5 倍）。1 回目は約 14 秒で、さらに遅い。AOT や ReadyToRun の指定はできない（無視される）。
- **CoreCLR は大きさと起動でも Mono に劣る**: 圧縮前で 9.54 MB（Mono インタープリター版の 1.26 倍）、ランタイムが使えるまでの時間も 30〜50 ms 長い。
- 1-3 の調査（「.NET 11 では CoreCLR は試験的で、既定は Mono のまま。完全な対応は .NET 12」）と合う結果だった。今ブラウザで C# を使うなら、**Mono の AOT 版**（重い計算）か **Mono のインタープリター版**（起動と配信の軽さ優先）。
- **.NET 11 では Node.js 用のテンプレートがなくなった**が、ブラウザ版の出力を Node.js から読み込めば、そのまま動く（Mono も CoreCLR も）。

### 6-8. 確かめていないこと

- CoreCLR の Release の publish でのリンクの失敗（`SystemJS_ExecuteTimerCallback`）の原因。SDK の不具合か、設定が足りないのか
- CoreCLR の 1 回目が 2 回目以降より約 5 秒遅い理由（インタープリターの準備、型の読み込み、V8 の最適化の待ちなど）
- CoreCLR で `WasmBuildNative=false` にしたことが速さに影響しているか（ランタイムを作り直した版と比べられていない）
- .NET 11 の Mono の大きさが .NET 10 より増えた内訳
- .NET 11 で Node.js 用のアプリを作る公式の方法（テンプレートがなくなった理由と、代わりの手順）
- `perf-open-questions.md` との関係: Q5 に、.NET 11 の Mono AOT 版の 1 回目（948 ms、約 2.5 倍）が加わる。CoreCLR のインタープリターの遅さは、Wasm の機械語の問題ではなく、インタープリターそのものの問題なので、Q1〜Q4 とは別

---

## 参照した情報

- [Getting Started with Swift SDKs for WebAssembly（swift.org）](https://www.swift.org/documentation/articles/wasm-getting-started.html)
- [Install Swift - macOS（swift.org）](https://www.swift.org/install/macos/)
- [Compiling Swift to WebAssembly: Sizes & Sharp Edges](https://patchrelease.com/blog/swift-to-webassembly)
- [componentize-dotnet の README](https://github.com/bytecodealliance/componentize-dotnet/blob/main/README.md)
- [componentize-dotnet のリリース](https://github.com/bytecodealliance/componentize-dotnet/releases)
- [Simplifying components for .NET/C# developers with componentize-dotnet（Bytecode Alliance）](https://bytecodealliance.org/articles/simplifying-components-for-dotnet-developers-with-componentize-dotnet)
- [C# - The WebAssembly Component Model](https://component-model.bytecodealliance.org/language-support/building-a-simple-component/csharp.html)
- [.NET 11 Preview 1 のランタイムのリリースノート](https://github.com/dotnet/core/blob/main/release-notes/11.0/preview/preview1/runtime.md)
- [Under the hood with .NET 11 Preview 1（InfoWorld）](https://www.infoworld.com/article/4138881/under-the-hood-with-net-11-preview-1.html)
- [CoreCLR on WebAssembly (.NET 11 RC2) の検証（GitHub の PR）](https://github.com/meneerkrabs/OpenTPW/pull/341)
- [[wasi][coreCLR] Track out-of-process runtime tests disabled on WASI（dotnet/runtime #136046）](https://github.com/dotnet/runtime/issues/136046)
- [Running .NET in the browser without Blazor（Andrew Lock）](https://andrewlock.net/running-dotnet-in-the-browser-without-blazor)
- [Run .NET from JavaScript（Microsoft Learn）](https://learn.microsoft.com/en-us/aspnet/core/client-side/dotnet-interop)
- [ASP.NET Core Blazor WebAssembly build tools and AOT compilation（Microsoft Learn）](https://learn.microsoft.com/en-us/aspnet/core/blazor/webassembly-build-tools-and-aot)
- [.NET 10 Blazor WebAssembly calling C# from JavaScript（Microsoft Q&A）](https://learn.microsoft.com/en-us/answers/questions/5763020/net-10-blazor-webassembly-calling-c-from-javascrip)
- NuGet の `Microsoft.NET.Runtime.Emscripten.3.1.56.Sdk.linux-arm64` などのパッケージ（大きさは nuget.org で確認）
