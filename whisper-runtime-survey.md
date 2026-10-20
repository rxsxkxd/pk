# Whisper ローカル推論ランタイム調査

調査日: 2026-10-20

対象:
- エンジン: **CTranslate2** / **faster-whisper** / **whisper.cpp**
- バインディング: **go-whisper-ct2** / **napi-rs (@napi-rs/whisper)** / **whisper.spm**
- 言語: Python / Go / Ruby / TypeScript / Swift / Kotlin
- OS: Windows / macOS / iOS / iPadOS

---

## 1. 結論

| 要件 | 推奨 |
|---|---|
| Python + NVIDIA GPU（サーバ・Windows デスクトップ） | **faster-whisper**（CTranslate2） |
| iOS / iPadOS を含むクロスプラットフォーム | **whisper.cpp**（CTranslate2 は iOS 非対応） |
| macOS で GPU / ANE を使う | **whisper.cpp**（Metal + Core ML）。CTranslate2 は macOS では CPU のみ |
| Swift | whisper.cpp の **XCFramework**（whisper.spm はアーカイブ予定） |
| Kotlin (Android) | whisper.cpp を JNI 経由で使う（公式 Kotlin バインディングはない） |
| Go | whisper.cpp 公式 `bindings/go`。CT2 系なら go-whisper-ct2（CPU のみ） |
| Ruby | whisper.cpp 公式 gem `whispercpp` |
| TypeScript / Node | whisper.cpp 系アドオン（smart-whisper, whisper-cpp-node など）。`@napi-rs/whisper` はまだ開発途中 |

**一言でまとめると:** Apple 系 OS（特に iOS/iPadOS）を含めるなら whisper.cpp 一択。Windows/Linux の NVIDIA GPU で最高スループットを狙うなら faster-whisper。

---

## 2. エンジン詳細

### 2.1 CTranslate2

| 項目 | 内容 |
|---|---|
| 概要 | OpenNMT の Transformer 推論エンジン（C++）。Whisper 以外のモデルにも対応 |
| 最新版 | **4.8.3**（PyPI, 2026-10-13） |
| API | C++ / Python |
| CPU バックエンド | Intel MKL, oneDNN, OpenBLAS, Ruy, Apple Accelerate（実行時に AVX/AVX2 等を自動選択） |
| GPU バックエンド | **CUDA**（NVIDIA）。AMD **ROCm** は Releases ページの専用 wheel で提供。**Metal 非対応** |
| 量子化 | FP16 / BF16 / INT16 / INT8 / AWQ(INT4)、INT8+FP16 などの組み合わせも可 |
| PyPI wheel | Linux x86-64・ARM64 / **Windows x86-64** / **macOS 11+ x86-64・ARM64**。CPython 3.9〜3.14（3.14t も含む） |
| iOS / iPadOS | **非対応**（公式ビルドも事例も見つからなかった） |

注意:
- macOS 版は CPU 推論のみ（Apple Silicon でも GPU / ANE は使わない）。
- 以前の macOS wheel には oneDNN が入っておらず、Conv1D でエラーになる報告があった（古いスレッド）。現行版で起きるかは確認していない。

### 2.2 faster-whisper

| 項目 | 内容 |
|---|---|
| 概要 | CTranslate2 で再実装した Whisper（SYSTRAN）。openai/whisper と同じ精度で最大約 4 倍速いとされる |
| 最新版 | **1.2.1**（PyPI, 2025-10-31） |
| 要件 | Python ≥ 3.9。音声デコードに PyAV を使うため FFmpeg のインストールは不要 |
| GPU | CUDA 12 + cuBLAS + cuDNN 9。古い環境では ctranslate2 を固定する: `3.24.0`（CUDA 11 / cuDNN 8）、`4.4.0`（CUDA 12 / cuDNN 8） |
| 機能 | `BatchedInferencePipeline`（バッチ推論）、単語タイムスタンプ、Silero VAD（`vad_filter`）、INT8/FP16、Transformers 形式モデルの変換 |
| モデル | `large-v3`, `turbo`, `distil-large-v3` などの名前を指定すると HF Hub から自動取得。CT2 形式に変換した独自モデルも使える |
| OS | Linux / Windows（CPU・CUDA）、macOS（CPU のみ）。pip で入る NVIDIA ライブラリは Linux 専用なので、Windows では cuBLAS/cuDNN の DLL を別途用意する |

**ベンチマーク**（README、13 分の音声）:

| 条件 | 実装 | 時間 | メモリ |
|---|---|---|---|
| large-v2 / RTX 3070 Ti | openai/whisper | 2m23s | 4708MB VRAM |
| | faster-whisper fp16 | 1m03s | 4525MB |
| | faster-whisper fp16, batch=8 | **17s** | 6090MB |
| | faster-whisper int8 | 59s | 2926MB |
| small / i7-12700K 8 スレッド | openai/whisper | 6m58s | 2335MB RAM |
| | faster-whisper int8 | 1m42s | 1477MB |
| | faster-whisper int8, batch=8 | **51s** | 3608MB |

README によると、条件次第では whisper.cpp の方が速いケースもある。

### 2.3 whisper.cpp

| 項目 | 内容 |
|---|---|
| 概要 | Whisper の C/C++ 移植（ggml-org）。依存なし、組み込み向け |
| 最新版 | **v1.9.5**（2026-10-06, ggml v0.26.0 に追従した保守リリース） |
| 対応 OS | macOS (Intel/Arm) / **iOS** / Android / Linux / FreeBSD / **Windows (MSVC, MinGW)** / WebAssembly / Raspberry Pi / Docker |
| Apple 向け高速化 | **Metal**（GPU で全推論）、**Core ML**（エンコーダを ANE で実行）、Accelerate、NEON、ANEForge |
| その他 GPU/NPU | CUDA、Vulkan（ベンダー非依存。Windows の AMD/Intel GPU 向け）、ROCm/HIP、OpenVINO、Ryzen AI NPU、Ascend CANN、MUSA |
| 量子化 | Q4/Q5/Q8 などの整数量子化（`quantize` ツール） |
| モデル形式 | 独自の ggml `.bin`（HF から変換済みのものを取得できる）。Core ML は別途 `-encoder.mlmodelc`、OpenVINO は IR 形式を用意 |
| 公式バインディング（同リポジトリ内） | `bindings/go`, `bindings/ruby`, `bindings/javascript`, `bindings/java` |
| README 掲載の外部バインディング | Rust (whisper-rs), Python (pywhispercpp ほか), .NET, R, Unity, Swift (whisper.spm → XCFramework) |

Core ML を使う場合:
```sh
./models/generate-coreml-model.sh base.en
cmake -B build -DWHISPER_COREML=1
```

Vulkan を使う場合（Windows で NVIDIA 以外の GPU）:
```sh
cmake -B build -DGGML_VULKAN=1
```

既知の問題: iOS 26.2 では、バックグラウンドへ移ったときに実行中の Metal コマンドバッファが中断され、アプリがクラッシュする報告がある（[#3531](https://github.com/ggml-org/whisper.cpp/issues/3531)）。iOS でバックグラウンド文字起こしをするなら、CPU へのフォールバックか処理の中断を設計しておく。

---

## 3. 個別バインディング

### 3.1 go-whisper-ct2（xPrimeTime）

- リポジトリ: https://github.com/xPrimeTime/go-whisper-ct2 （MIT）
- **CTranslate2 を Go から呼ぶ**ラッパー。Python なしで faster-whisper 形式のモデルを動かす。
- 構成: Go (cgo) → C API (`whisper_ct2.h`) → C++ 共有ライブラリ `libwhisper_ct2` → CTranslate2 **4.7.1**（ビルド時に固定）。音声処理は libsndfile、libsamplerate、PocketFFT。Silero VAD は onnxruntime を使う（`WITH_SILERO_VAD=OFF` で無効にできる）。
- **CPU のみ**（`Device` は `"cpu"` しか受け付けない）。
- OS: Linux / macOS の手順のみ。**Windows は記載なし**。
- `go get` だけでは使えず、先に `make` で C++ ライブラリをビルドする必要がある。
- モデル: Systran の faster-whisper リポジトリ（`model.bin`, `config.json`, `tokenizer.json`, `vocabulary.txt`）。
- 性能: whisper-small で faster-whisper より約 1.23 倍遅い（`OMP_NUM_THREADS` を調整した場合）。調整しないと約 2 倍遅い。
- pkg.go.dev の最新タグは v1.1.0。

```go
model, err := whisper.LoadModel("./whisper-small-ct2", whisper.DefaultModelConfig())
result, err := model.TranscribeFile("audio.wav")
fmt.Println(result.Text)
```

### 3.2 napi-rs 系 Whisper バインディング（`@napi-rs/whisper`）

- 「napi-rs/whisper-bindings」という名前のリポジトリやパッケージは見つからなかった。該当しそうなのは **`@napi-rs/whisper`**（ソース: [Brooooooklyn/whisper-node](https://github.com/Brooooooklyn/whisper-node), MIT）。
- Rust（napi-rs）製の Node アドオンで、whisper.cpp を submodule として直接ラップしている。
- 最新版は 0.0.4。README には **「開発途中、現在は macOS のみ対応」** とある。npm には `darwin-arm64` / `darwin-x64` / `linux-x64-gnu` 向けのバイナリもある。**Windows 版はない**。
- GPU（Metal/CUDA）についての記載はない。Release もない。→ **本番利用は推奨しない**。

```ts
const whisper = new Whisper(modelBuffer)            // ggml モデル
const params = new WhisperFullParams(WhisperSamplingStrategy.Greedy)
params.language = 'ja'
const pcm = await decodeAudioAsync(buf, 'a.wav')
whisper.full(params, pcm)
```

Node/TS で使える代替:

| パッケージ | 特徴 |
|---|---|
| **smart-whisper** | Windows/macOS/Linux 対応。macOS では GPU を自動で使う。Linux/Windows の GPU は自前でビルドした libwhisper を `BYOL` で指定 |
| **whisper-cpp-node** | ビルド済みバイナリあり: `darwin-arm64` (Metal)、`win32-x64` (Vulkan) |
| **nwhisper** | nodejs-whisper の後継。ビルドに make などが必要 |
| whisper.cpp `bindings/javascript` / `examples/addon.node` | 公式（WASM / ネイティブアドオンの例） |

### 3.3 whisper.spm

- リポジトリ: https://github.com/ggml-org/whisper.spm
- whisper.cpp を Swift Package Manager で使うためのパッケージ。**「まもなくアーカイブされメンテナンスされない」** と明記されており、whisper.cpp 本体の Swift パッケージを使うよう案内している（最終 push は 2024-05）。
- **代わりの方法**: whisper.cpp の Releases にある **XCFramework**（iOS / macOS / visionOS / tvOS 向けのビルド済みバイナリ）を `binaryTarget` として参照する。

```swift
// Package.swift
.binaryTarget(
    name: "whisper",
    url: "https://github.com/ggml-org/whisper.cpp/releases/download/v<VER>/whisper-v<VER>-xcframework.zip",
    checksum: "<sha256>"
)
```
（README の例は v1.7.5。使うバージョンの checksum は `swift package compute-checksum` で求める）

- 高レベルなラッパー: **SwiftWhisper**（exPHAT, Core ML 対応）。Core ML / ANE に最適化された別系統のエンジンとして WhisperKit（Argmax）もある。

---

## 4. 言語 × エンジン 対応表

| 言語 | CTranslate2 / faster-whisper | whisper.cpp |
|---|---|---|
| **Python** | ◎ faster-whisper（本命） / ctranslate2 | ○ pywhispercpp（1.5.0, 2026-05） |
| **Go** | △ go-whisper-ct2（CPU のみ、要 C++ ビルド） | ○ 公式 `bindings/go`（cgo + `libwhisper.a`、CUDA ビルド可） |
| **Ruby** | ✕（公式なし） | ○ 公式 gem `whispercpp`（`--enable-ggml-cuda` などのビルドオプションあり。Windows 対応は「協力募集中」） |
| **TypeScript/Node** | ✕（実用的なものなし） | ○ smart-whisper / whisper-cpp-node など。△ `@napi-rs/whisper`（WIP） |
| **Swift** | ✕ | ◎ XCFramework（公式）/ SwiftWhisper。whisper.spm は非推奨 |
| **Kotlin** | ✕ | ○ JNI（公式 `examples/whisper.android`、`bindings/java`、Arm KleidiAI のサンプル、ビルド済み AAR などのサードパーティ製） |

◎ 推奨 / ○ 実用的 / △ 制約あり / ✕ なし

## 5. OS × エンジン 対応表

| OS | CTranslate2 / faster-whisper | whisper.cpp |
|---|---|---|
| **Windows** | ◎ x86-64 wheel、CUDA 対応（cuBLAS/cuDNN の DLL は別途用意） | ◎ MSVC/MinGW、CUDA / Vulkan / OpenVINO。ビルド済みバイナリあり |
| **macOS** | △ CPU のみ（Accelerate/Ruy）、Intel・Apple Silicon の wheel あり | ◎ Metal + Core ML (ANE) |
| **iOS** | ✕ | ◎ XCFramework、Metal / Core ML |
| **iPadOS** | ✕ | ◎ iOS と同じ XCFramework |

## 6. 言語 × OS で実際に選ぶもの

| | Windows | macOS | iOS / iPadOS |
|---|---|---|---|
| Python | faster-whisper (CUDA) | pywhispercpp (Metal) または faster-whisper (CPU) | — |
| Go | whisper.cpp bindings/go（go-whisper-ct2 は Windows 記載なし） | whisper.cpp bindings/go | —（gomobile は現実的でない） |
| Ruby | whispercpp（Windows は要検証） | whispercpp | — |
| TypeScript | whisper-cpp-node (Vulkan) / smart-whisper | smart-whisper / whisper-cpp-node (Metal) | （React Native なら whisper.rn などの別系統。未調査） |
| Swift | — | whisper.cpp XCFramework | whisper.cpp XCFramework |
| Kotlin | （JVM なら bindings/java） | （同左） | —（Kotlin Multiplatform で iOS を狙うなら cinterop で whisper.cpp を呼ぶ。未検証） |

## 7. モデル形式の違い（重要）

| エンジン | 形式 | 入手先 |
|---|---|---|
| CTranslate2 / faster-whisper / go-whisper-ct2 | CT2 形式（`model.bin` + `config.json` + `tokenizer.json` + `vocabulary.txt`） | HF `Systran/faster-whisper-*`、または `ct2-transformers-converter` で変換 |
| whisper.cpp 系すべて | ggml `.bin`（量子化版あり）＋ 必要なら Core ML / OpenVINO 用のエンコーダ | HF `ggerganov/whisper.cpp`、`download-ggml-model.sh` |

→ 2 系統のエンジンを併用するとモデルを二重に管理することになる。Apple 系と Windows を 1 つのコードベースで扱うなら、whisper.cpp に統一すると管理が楽になる。

---

## 8. 未確認・要検証事項

- whisper.cpp v1.9.5 の Release に XCFramework / Windows CUDA zip が添付されているか（Release ページで添付数「2」しか確認できなかった。旧リリースでは添付されていた）
- whispercpp gem と pywhispercpp の Windows 向けビルド済みバイナリの有無
- `@napi-rs/whisper` の最終更新日（npm の表示が「9 か月前〜2 年前」と食い違っている）
- 現行の CTranslate2 macOS wheel に oneDNN が入っているか

## 参考リンク

- CTranslate2: https://github.com/OpenNMT/CTranslate2 / https://pypi.org/project/ctranslate2/
- faster-whisper: https://github.com/SYSTRAN/faster-whisper / https://pypi.org/project/faster-whisper/
- whisper.cpp: https://github.com/ggml-org/whisper.cpp （releases, bindings/go, bindings/ruby）
- go-whisper-ct2: https://github.com/xPrimeTime/go-whisper-ct2 / https://pkg.go.dev/github.com/xPrimeTime/go-whisper-ct2
- @napi-rs/whisper: https://www.npmjs.com/package/@napi-rs/whisper / https://github.com/Brooooooklyn/whisper-node
- whisper.spm: https://github.com/ggml-org/whisper.spm
- SwiftWhisper: https://swiftpackageregistry.com/exPHAT/SwiftWhisper
- pywhispercpp: https://www.piwheels.org/project/pywhispercpp/
- smart-whisper: https://classic.yarnpkg.com/en/package/smart-whisper
- whisper-cpp-node: https://cdn.jsdelivr.net/npm/whisper-cpp-node@0.2.12/README.md
- iOS Metal バックグラウンドでのクラッシュ: https://github.com/ggml-org/whisper.cpp/issues/3531
- Android JNI (Arm KleidiAI): https://us-west-2b-production.gl-awslz.arm.com/kleidi/kleidi-examples/speech-to-text/-/blame/main/README.md
