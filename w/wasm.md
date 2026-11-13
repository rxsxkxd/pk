# C# / Rust から WebAssembly を作る方法の整理（内容の再確認）

確認日: 2026-11-12（同日にネットで再調査し、Unity の WebGPU の記述を修正）

元の説明（Unity の WebGL ビルドと Microsoft の .NET の比較、C# から Wasm を作る 3 つのルート、Rust のビルドターゲット比較）を、記述ごとに確かめて書き直した。各項目の判定は次の 4 つで示す。

- **正確**: 記述のとおり
- **補足**: 大筋は正しいが、条件や言い足りない点がある
- **要修正**: 事実と違う、または誤解を招く
- **未確認**: 公式の情報で確かめきれていない

---

## 用語

似た名前が多いので、この文書では次の名前で書き分ける。

| 名前 | 指すもの |
|---|---|
| **Unity Web ビルド** | Unity でブラウザ向けに書き出すビルド。Unity 2022 までは「WebGL」、Unity 6 からは「Web」というプラットフォーム名 |
| **IL2CPP** | Unity 独自の変換器。C# をコンパイルした IL（中間言語）を C++ のソースに変換する |
| **Blazor WebAssembly** | Microsoft の .NET でブラウザ向けアプリを作る仕組み。中で **Mono ランタイム** の Wasm 版が動く |
| **Mono AOT** | Blazor WebAssembly で任意に有効にできる事前コンパイル（`RunAOTCompilation`）。IL を LLVM 経由で Wasm にする |
| **.NET Native AOT** | .NET 7 以降に正式に入った事前コンパイル機能。対象は Windows / Linux / macOS などのネイティブで、**Wasm は正式な対象ではない** |
| **NativeAOT-LLVM** | .NET Native AOT を Wasm 向けにした**実験版**。`dotnet/runtimelab` リポジトリの feature ブランチで開発されている |
| **Emscripten** | C/C++ を Wasm と JavaScript の「つなぎのコード」に変換するツール一式。内部で LLVM（clang）を使う |
| **WASI** | ブラウザの外で Wasm を動かすための標準インターフェース（ファイル、標準入出力など） |

---

## 1. Unity の Web ビルドは Microsoft の .NET の Wasm 機能を使っているか

**元の記述**: 使っていない。Unity は IL2CPP と Emscripten（LLVM）で C# を WebAssembly に変換している。

**判定: 正確**

Unity Web ビルドの流れは次のとおり。

```
C# ──(Roslyn)──▶ IL ──(IL2CPP)──▶ C++ ──(Emscripten / clang・LLVM)──▶ .wasm + JS
                                   ＋ Unity エンジン本体（C++）
```

Emscripten は Unity エディタに同梱されていて、利用者が別に入れる必要はない。

---

## 2. 仕組みの違い（Unity と Microsoft の .NET）

**元の記述**: どちらも最後は LLVM（Emscripten）を通って .wasm を作る。違うのはそこまでの変換の流れ。

**判定: 補足**

「どちらも C# を Wasm に変換している」と読める書き方になっているが、Blazor WebAssembly は**標準の設定では C# を Wasm に変換しない**。

| | Unity Web ビルド | Blazor WebAssembly（標準） | Blazor WebAssembly（Mono AOT 有効） |
|---|---|---|---|
| Wasm になるもの | C# のコード（C++ 経由）とエンジン本体 | **Mono ランタイムだけ**（Microsoft がビルドしたものが配られる） | ランタイムと、C# のコード（LLVM 経由） |
| C# のコードの扱い | 事前に機械語（Wasm）に変換 | **IL（.dll / .wasm 形式に包んだもの）のまま配り、ブラウザ上の Mono インタープリターが実行** | 事前に Wasm に変換（一部はインタープリターで実行） |
| 手元で Emscripten を使うか | 使う（Unity に同梱） | 使わない | 使う（`wasm-tools` ワークロードで入る） |

つまり「LLVM（Emscripten）を通る」のは、Blazor の場合はランタイムの側と、Mono AOT を有効にしたときに限られる。

---

## 3. Unity が IL2CPP を使い続ける理由

### 3-1. エンジン本体（C++）との密結合

**元の記述**: エンジン本体が C++ なので、C# を C++ にする IL2CPP の方が描画（WebGL / WebGPU）や物理演算と速く連携できる。

**判定: 補足**

大きな理由が抜けている。**ブラウザの Wasm 上では、実行時に機械語を作る JIT が使えない**。Unity がもともと使っていた Mono は JIT で C# を動かすため、Wasm、iOS、ゲーム機のように JIT が許されない環境では、事前に全部を機械語にしておく仕組み（AOT）が必要になる。IL2CPP はその役目を担っている。

「C++ との連携が速い」という点は、IL2CPP の利点としては筋が通るが、Web ビルドで IL2CPP を使う第一の理由ではない。

また、WebGPU は Unity 6.1 で**実験的な機能として**一般に公開された。Unity 6.6 で正式な機能になったという報道（2026-09）があるが、Unity 6.6 ベータのマニュアルではまだ実験的と書かれていて、公式の情報では確かめられていない。どちらにしても、Web ビルドの標準の描画は WebGL 2 で、WebGPU は設定で自分で追加する。

### 3-2. ゲーム機などとの共通化

**元の記述**: IL2CPP はブラウザ専用ではなく、iOS やゲーム機向けのネイティブビルドでも使われる共通基盤。

**判定: 正確**

### 3-3. CoreCLR への移行

**元の記述**: Unity は CoreCLR への移行を進めているが、Web ビルドでは今も IL2CPP の流れが標準。

**判定: 正確（補足あり）**

2026 年時点の Unity の発表とコミュニティ向けの報告では、次のとおり。

- 置き換わるのは **Mono（JIT）の部分**で、CoreCLR がその後を継ぐ。選択肢は「Mono か IL2CPP か」から「CoreCLR か IL2CPP か」に変わる
- **IL2CPP は廃止されず**、事前コンパイル（AOT）の方式として残る。モバイルやゲーム機は IL2CPP のまま
- CoreCLR はまずデスクトップ向けのプレイヤーとエディタから入っていて、Unity 6.7 で実験的に使えるようになった。Mono を外したエディタは Unity 7.0 として alpha 版が出ている
- Web ビルドに CoreCLR を使う予定は見つからなかった。Web は今後も IL2CPP で、別の改善（WASM64 で使えるメモリを広げる、WebGPU を正式に使えるようにする）が話題になっている（**未確認**: Web 向けの具体的な時期は公式の情報で確かめられていない）

---

## 4. 役割の棲み分け

**元の記述**: Unity はグラフィックスを重視するゲームや 3D 向け、Blazor は業務 Web アプリや管理画面向け。

**判定: 正確**

付け加えると、どちらも初回の読み込みが重くなりやすい。Unity Web ビルドは数 MB から数十 MB、Blazor WebAssembly もランタイムを含めて数 MB になる。軽い Web ページに C# のロジックを少しだけ足す、といった用途にはどちらも向かない。

---

## 5. C# から WebAssembly を作る 3 つのルート

元の表には誤りがあるので、直したものを先に示す。

| ルート | 位置づけ | Emscripten の要否 | 仕組み | 大きさの目安 |
|---|---|---|---|---|
| ① Unity Web ビルド | Unity の正式機能 | 必要（Unity に同梱） | IL2CPP で C++ にし、エンジン本体と一緒に Emscripten で Wasm にする | 大きい（数 MB〜） |
| ② Blazor WebAssembly | .NET の正式機能 | 標準では不要。Mono AOT を使うときは必要（`wasm-tools` で入る） | Wasm 化した Mono ランタイムの上で IL を実行。Mono AOT を使えば C# も Wasm にする | 数 MB〜 |
| ③ NativeAOT-LLVM | **実験版**（runtimelab） | **ブラウザ向けは必要**。WASI 向けは不要（WASI SDK を使う） | IL を LLVM 経由で直接 Wasm にする。ランタイムも小さいものが一緒に入る | ①②より小さい（具体的な数字は**未確認**） |
| ④ .NET の `wasi-wasm`（`wasi-experimental` ワークロード） | **実験版**。.NET 9 で外され、.NET 10 でも実用にならない状態と報告されている | 不要（WASI SDK を使う） | Mono ランタイムを WASI 向けにしたもの | — |

### 元の表から直したところ

- **元の ① で Unity と Blazor をひとまとめにしていた点**: Blazor は標準では C# を Wasm にしない（2 章のとおり）ので、分けた。
- **元の ②「.NET Native AOT（Wasm ターゲット）は Emscripten 不要」**: **要修正**。
  - .NET の正式な Native AOT は Wasm を対象にしていない。Wasm 向けは runtimelab の実験版 NativeAOT-LLVM。
  - NativeAOT-LLVM でも、**ブラウザ向け（`browser-wasm`）は Emscripten を使う**。Emscripten が要らないのは WASI 向け（`wasi-wasm`）のときだけ。
  - 「数百 KB〜」という大きさは、公式の数字を見つけられなかった（**未確認**）。
- **元の ③「WASI 対応ビルド（wasi-wasm）」**: **補足**。.NET の正式な SDK が出していた `wasi-experimental` は実験扱いで、.NET 9 で外されている。今 C# で WASI 向けの Wasm を作るなら、NativeAOT-LLVM を使う `componentize-dotnet` などの外部の手段が中心になる。ブラウザの外（Wasmtime などのサーバーやエッジ）で動かすための方式という説明は正しい。

---

## 6. Rust の Wasm ビルドターゲット比較

| 比較項目 | `wasm32-unknown-unknown` | `wasm32-unknown-emscripten` |
|---|---|---|
| 概要 | LLVM で Rust から直接 Wasm を作る。OS も C 標準ライブラリも前提にしない | Emscripten の環境（C 標準ライブラリ、POSIX の模倣、JS のつなぎのコード）の上で Wasm を作る |
| 大きさ | 小さい。最小なら数 KB、wasm-bindgen を使った一般的なものは数十〜数百 KB | 比べると大きくなりやすい（つなぎのコードと C 標準ライブラリが入るため） |
| 主なツール | wasm-pack、wasm-bindgen、Trunk | Emscripten SDK（emcc） |
| 得意なこと | Web アプリ、JS 向けライブラリ、DOM 操作（wasm-bindgen / web-sys 経由）、計算処理 | 既存の C/C++ ライブラリとの組み合わせ、OpenGL / SDL を使ったものの移植 |

**判定: 正確（補足あり）**

- **`wasm32-unknown-unknown` が今の主流**という点は正しい。
- **大きさ**: 「数 KB〜数十 KB」は小さな例の値で、wasm-bindgen を使った普通のアプリでは数十〜数百 KB になる。また Emscripten 側も最適化すれば小さくでき、「数百 KB〜」と決まっているわけではない。差の理由（つなぎのコードと C 標準ライブラリ）は元の説明のとおり。
- **`wasm32-unknown-unknown` の制約**: OS がない前提なので、標準ライブラリのうちファイル、スレッド、時刻などは使えないか、呼ぶと失敗する。ブラウザの機能は wasm-bindgen / web-sys / js-sys 経由で使う。
- **抜けているターゲット**: ブラウザの外で動かす **WASI 向け**のターゲットがある。
  - `wasm32-wasip1`（以前の名前は `wasm32-wasi`。Rust 1.78 で改名され、旧名は 1.84 で削除）
  - `wasm32-wasip2`（WASI 0.2 / コンポーネントモデル向け。Rust 1.82 で Tier 2）

---

## まとめ（元の説明から直すべき点）

1. **Blazor WebAssembly は標準では C# を Wasm に変換しない。** Wasm になっているのは Mono ランタイムで、C# は IL のままインタープリターで動く。Wasm に変換するのは Mono AOT を有効にしたとき。
2. **「.NET Native AOT で Wasm、Emscripten 不要」は誤り。** Wasm 向けは実験版の NativeAOT-LLVM で、ブラウザ向けでは Emscripten を使う。
3. **.NET の `wasi-wasm` は実験扱いで、.NET 9 で外された。**
4. **Unity が IL2CPP を使う第一の理由は、Wasm 上で JIT が使えないこと。**
5. **Rust には WASI 向けのターゲット（`wasm32-wasip1` / `wasm32-wasip2`）もある。**

---

## 参照した情報

- [ASP.NET Core Blazor WebAssembly build tools and AOT compilation（Microsoft Learn）](https://learn.microsoft.com/aspnet/core/blazor/webassembly-build-tools-and-aot)
- [Public access to WebGPU (experimental) in Unity 6.1（Unity Discussions）](https://discussions.unity.com/t/public-access-to-webgpu-experimental-in-unity-6-1/1572462)
- [Unity 6.6 Beta マニュアル: WebGPU limitations](https://docs.unity3d.com/6000.6/Documentation/Manual/WebGPU-limitations.html)
- [Updates to Rust's WASI targets（Rust Blog）](https://blog.rust-lang.org/2024/04/09/updates-to-rusts-wasi-targets/)
- [The wasm32-wasip2 Target Has Reached Tier 2 Support（Rust Blog）](https://blog.rust-lang.org/2024/11/26/wasip2-tier-2/)

- [CoreCLR, Scripting, and Serialization Update - June 2026（Unity Discussions）](https://discussions.unity.com/t/coreclr-scripting-and-serialization-update-june-2026/1723299)
- [CoreCLR, Scripting, and ECS Status Update - March 2026（Unity Discussions）](https://discussions.unity.com/t/coreclr-scripting-and-ecs-status-update-march-2026/1711852)
- [Unity and .NET, what's next?（Unity Blog）](https://unity.com/blog/engine-platform/unity-and-net-whats-next)
- [Unity Engine 7: Changing the Development Paradigm and the Roadmap Ahead（Inven Global）](https://www.invenglobal.com/articles/24003/unity-engine-7-changing-the-development-paradigm-and-the-roadmap-ahead)
- [Unity's 2026 Roadmap: CoreCLR, Verified Packages, Fewer Surprises（Digital Production）](https://digitalproduction.com/2025/11/26/unitys-2026-roadmap-coreclr-verified-packages-fewer-surprises/)
- [dotnet/runtimelab: NativeAOT-LLVM の Emscripten ビルドに関する PR #2453](https://github.com/dotnet/runtimelab/pull/2453)
- [dotnet/runtimelab issue #2235（browser-wasm 向けの構成例）](https://github.com/dotnet/runtimelab/issues/2235)
- [Extending WebAssembly to the Cloud with .NET（.NET Blog, 2023-12）](https://devblogs.microsoft.com/dotnet/extending-web-assembly-to-the-cloud/)
- [WASI and .NET 9: Quo vadis?](https://henrikrxn.github.io/blog/Wasi-dotnet-9)
- [.NET 10: No WASI](https://henrikrxn.github.io/blog/Wasi-dotnet-10)

Rust のターゲット名の変更と Blazor WebAssembly の実行方式は、Rust と .NET の公式ドキュメントにもとづく既知の情報で、今回は Web で引き直していない。
