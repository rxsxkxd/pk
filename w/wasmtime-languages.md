# Wasmtime と組み合わせる言語の整理

確認日: 2026-11-12

Wasmtime と組み合わせて使う言語を、**ホスト側**（Wasmtime を自分のアプリに組み込む側）と **ゲスト側**（Wasmtime の上で動く `.wasm` を作る側）に分けて整理する。元にしたのは貼り付けられた説明で、記述ごとにネットで確かめた。判定の書き方は `wasm.md` と同じ。

- **正確**: 記述のとおり
- **補足**: 大筋は正しいが、条件や言い足りない点がある
- **要修正**: 事実と違う、または誤解を招く
- **未確認**: 確かめきれていない

**元の説明について**: 元の説明は、ホスト側もゲスト側も「2 位」から始まっていて、1 位が抜けている。文脈からすると、どちらの 1 位も **Rust** と考えられる（Wasmtime 自体が Rust で書かれていて、Rust の API がいちばん機能が揃っている）。この文書では 1 位を Rust として補った。

---

## 用語

| 名前 | 指すもの |
|---|---|
| **ホスト側** | Wasmtime をライブラリとして自分のアプリに組み込み、`.wasm` を読み込んで動かす側。`runtimes.md` の「③-a アプリへの組み込み」にあたる |
| **ゲスト側** | Wasmtime の上で動く `.wasm` を作る側 |
| **埋め込み API** | ホスト側から Wasmtime を操作するための API。本体は Rust の `wasmtime` クレートで、それを C から使えるようにしたものが **C API**（`wasmtime.h`） |
| **言語バインディング** | C API を包んで、Python、Go、.NET などから使えるようにしたライブラリ（wasmtime-py、wasmtime-go、wasmtime-dotnet） |
| **コアモジュール** | 従来の `.wasm`。数値しか直接受け渡せない。WASI 0.1 はこちらを前提にしている |
| **コンポーネント** | コンポーネントモデルに従った `.wasm`。WIT で決めたインターフェースで、文字列や構造体をそのまま受け渡せる。WASI 0.2 以降はこちらを前提にしている |

---

## 1. ホスト側（Wasmtime を組み込む）

### 1-1. 一覧

| 順位 | 言語 | 提供されているもの | コンポーネントの対応 | 注意 |
|---|---|---|---|---|
| 1 | **Rust** | `wasmtime` クレート（本体そのもの） | 対応（最も先行） | 新しい機能はまずここに入る |
| 2 | **C / C++** | C API（`wasmtime.h`）。C++ 向けのヘッダーも同じリポジトリにある | 対応（あとから追加。`wasmtime/component/linker.h` など） | 非同期まわりなどは Rust より遅れて入る |
| 3 | **Python** | wasmtime-py（PyPI の `wasmtime`） | 対応（`python -m wasmtime.bindgen` でつなぎのコードを生成） | Wasmtime 本体と同じく、毎月大きな版が上がる |
| 3 | **Go** | wasmtime-go | **未確認**（対応は限られる可能性） | C API を cgo で呼ぶので、**cgo が必須**（C のコンパイラが要る） |
| 3 | **.NET（C#）** | wasmtime-dotnet（NuGet の `Wasmtime`） | **未確認** | 1 年以上リリースが止まった時期がある。2026 年 5 月に 44.0.0 が出たという情報がある（未確認） |

### 1-2. 記述ごとの判定

**「C / C++: Wasmtime が公式に C API（`wasmtime.h`）を提供し、Rust 本体とほぼ同等のフル機能が使える。組み込み機器、ゲームエンジン、既存の C++ のサーバーに統合するときの第一の選択肢」**

**判定: 補足**

- C API が公式に提供されているのは正しい。Python、Go、.NET の言語バインディングも、この C API の上に作られている。
- 「ほぼ同等のフル機能」は言い過ぎ。新しい機能はまず Rust の API に入り、C API には後から入る。たとえばコンポーネントモデルは、C API では長く使えず、2024 年末ごろから追加が進んだ。今も、コンポーネントの非同期の API を C API に足す作業が続いている。
- 「組み込み機器の第一の選択肢」については、機器の大きさによる。メモリが小さい機器では、Wasmtime より WAMR などの小さな実行環境が選ばれることが多い（`runtimes.md` の ③-d）。

**「Python / Go / .NET: 公式のバインディング（wasmtime-py、wasmtime-go、Wasmtime.NET）が Bytecode Alliance で公式に保守されている。Python は AI・データ処理基盤、Go はクラウドインフラから、安全なサンドボックスとして Wasmtime を呼ぶ用途と親和性が高い」**

**判定: 補足**

- 3 つとも Bytecode Alliance のリポジトリにあり、公式という点は正しい。
- ただし、保守の度合いは同じではない。
  - **wasmtime-py**: 本体に合わせて毎月更新され、コンポーネントにも対応している。
  - **wasmtime-go**: C API を cgo で呼ぶ。Go から使うときに C のコンパイラが要り、クロスコンパイルが難しくなる。Go の利点（単一のバイナリ、簡単なクロスコンパイル）が一部失われる。
  - **wasmtime-dotnet**: 22.0.0 のまま 1 年以上止まっていた時期がある。その後再開したという情報はあるが、確かめきれていない。
- Go で組み込む場合は、cgo の要らない **wazero**（純粋な Go の実行環境）も候補になる。ただし wazero は WASI 0.1 とコアモジュールだけで、コンポーネントには対応していない（`runtimes.md` の 1 章）。

| Go でのホスト | cgo | WASI 0.1 | コンポーネント | 向いている場面 |
|---|---|---|---|---|
| wasmtime-go | 必要 | 対応 | 未確認 | Wasmtime の機能や速さが要るとき |
| wazero | 不要 | 対応 | 非対応 | 依存を増やしたくない、クロスコンパイルしたいとき |

---

## 2. ゲスト側（Wasmtime で動く `.wasm` を作る）

### 2-1. 一覧

| 順位 | 言語 | 使うもの | 作れるもの | 大きさの目安 | 注意 |
|---|---|---|---|---|---|
| 1 | **Rust** | 標準のツールチェーン（`wasm32-wasip1` / `wasm32-wasip2`） | コアモジュール、コンポーネント | 小さい（数十〜数百 KB） | 最も成熟している |
| 2 | **C / C++** | wasi-sdk（clang と WASI 用の C ライブラリの組み合わせ） | コアモジュール（コンポーネントは別のツールで変換） | 小さい | 既存の C/C++ のコードを持ち込みやすい |
| 3 | **Go** | 標準の Go（`GOOS=wasip1`、Go 1.21 以降） | コアモジュール（WASI 0.1） | **大きい**（hello で約 2.4 MB、マンデルブロ集合で約 4.5 MB。この作業での実測） | Go のランタイムがまるごと入る。関数を公開する `//go:wasmexport` は Go 1.24 以降 |
| 3 | **Go（TinyGo）** | TinyGo（`-target=wasip1` / `-target=wasip2`） | コアモジュール、コンポーネント（0.34.0 以降） | 標準の Go より小さい | 標準の Go と比べて使えないパッケージや機能がある |
| 4 | **Python** | componentize-py | コンポーネント | **大きい**（Python のインタープリターごと入る） | 出力が大きい。wasm-tools で余分な部分を削ると半分ほどになるという情報がある |
| 4 | **JavaScript** | ComponentizeJS（StarlingMonkey = SpiderMonkey をもとにした JS エンジン） | コンポーネント | **大きい**（足し算だけで約 8 MB という 2024 年の報告） | JS のエンジンごと入る |

### 2-2. 記述ごとの判定

**「C / C++（wasi-sdk）: Wasm の黎明期から最も成熟した言語の一つ。wasi-sdk で、標準ライブラリを含めた既存の C/C++ のコードを、軽量で高速な Wasm / WASI のバイナリにできる」**

**判定: 正確**

付け加えると、wasi-sdk が直接作るのはコアモジュール。コンポーネントにするには、別のツール（wasm-tools など）で変換する。

**「Go（特に TinyGo）: 標準の Go（1.21 以降）でも `GOOS=wasip1` で WASI 向けにビルドできるが、小さく速く動かしたいなら TinyGo が Wasmtime やコンポーネントモデルと非常に親和性が高い」**

**判定: 補足**

- 標準の Go の `GOOS=wasip1` は正しい。この作業でも実際に使い、Node.js、Deno、ブラウザで動いた（`runtimes.md` の 8 章・9 章）。標準の Go が作れるのは WASI 0.1 のコアモジュールだけで、コンポーネントは作れない。
- TinyGo は 0.34.0 から WASI 0.2 とコンポーネントを直接作れるようになった（`-target=wasip2`）。大きさは標準の Go の 7〜10 分の 1 という記事があるが、条件をそろえた比較ではない。
- 一方で、Bytecode Alliance のコンポーネントモデルの資料には「TinyGo 向けのコンポーネントのツールは今は保守されていない」という記述もある（**未確認**: どの範囲を指すのかは分からなかった）。「非常に親和性が高い」と言い切るのは避け、使う前に最新の状況を確かめる。
- 「速く動かしたい」について: この作業の計測（`runtimes.md` の 9 章）では、標準の Go の Wasm も、V8 で最適化が済めばネイティブとほぼ同じ速さだった。TinyGo で一番効くのは大きさで、速さは条件しだい。

**「Python / JavaScript（ComponentizeJS / componentize-py）: Wasmtime が推進するコンポーネントモデルの恩恵を強く受けている。専用のツールで、Python や JS のコードを Wasmtime 上で高速に起動できる単一の Wasm コンポーネントに変換できる」**

**判定: 補足**

- どちらも Bytecode Alliance のツールで、コンポーネントを作るという点は正しい。
- 「高速に起動できる」のは、初期化を前もって済ませた状態を `.wasm` に保存しておく仕組み（事前初期化）による。インタープリターの起動にかかる時間を省ける。
- ただし、どちらも **言語のインタープリターや JS のエンジンを `.wasm` に丸ごと入れる**ので、出力は大きくなる（JS は数 MB〜、Python はさらに大きい）。計算そのものの速さも、コンパイルする言語（Rust、C/C++、Go）には及ばない。
- 向いているのは、「既存の Python / JS のコードや開発者を、コンポーネントの仕組みに乗せたい」場合。速さや大きさを重視する計算部品には向かない。

### 2-3. 元の説明に入っていない言語（参考）

- **C#**: `componentize-dotnet`（実験版の NativeAOT-LLVM を使う）で、WASI 0.2 のコンポーネントを作れる。.NET の SDK の WASI 向けビルドは実験扱いのまま外された。詳しくは `wasm.md` の 5 章。
- **ホスト側のその他の言語**: Ruby（wasmtime-rb）などの言語バインディングもある。

---

## 3. この作業との関係

これまでの作業（`runtimes.md`）に当てはめると、次のようになる。

| やりたいこと | 候補 | 理由 |
|---|---|---|
| Go のアプリに計算部品の Wasm を組み込む（ホスト側） | まず **wazero**、Wasmtime の機能が要るなら wasmtime-go | wazero は cgo が要らない。今の計算部品は WASI 0.1 のコアモジュールで足りる |
| 計算部品を小さく作る（ゲスト側） | **Rust**、または **TinyGo** | 標準の Go は 4.5 MB と大きい。ブラウザで配るなら特に効く |
| 型付きのインターフェースで受け渡したい | Rust（ゲスト）＋ Wasmtime（ホスト）のコンポーネント | コンポーネントに対応している組み合わせが最も確実。ただし wazero、Node.js、Deno では動かせない |
| Python のデータ処理から計算部品を呼ぶ（ホスト側） | wasmtime-py | コンポーネントにも対応していて、更新も続いている |

---

## 参照した情報

- [Wasmtime C API のドキュメント](https://docs.wasmtime.dev/c-api/annotated.html)
- [Wasmtime: コンポーネントモデルを C API に追加する issue #6987（Zulip のアーカイブ）](https://bytecodealliance.github.io/zulip-archive/stream/225357-git-wasmtime/topic/wasmtime.20.2F.20issue.20.236987.20Add.20component.20model.20support.20to.20the.2E.2E.2E.html)
- [Wasmtime: コンポーネントモデルを C API で公開する PR #9812（Zulip のアーカイブ）](https://bytecodealliance.github.io/zulip-archive/stream/225357-git-wasmtime/topic/wasmtime.20.2F.20PR.20.239812.20Expose.20component.20model.20in.20C.20api.html)
- [Wasmtime: コンポーネントの C API に非同期を追加する PR #12973（Zulip のアーカイブ）](https://bytecodealliance.github.io/zulip-archive/stream/225357-git-wasmtime/topic/wasmtime.20.2F.20PR.20.2312973.20Add.20async.20support.20to.20the.20component.20m.2E.2E.2E.html)
- [wasmtime-cli 45.0.1: WASI API のドキュメント](https://docs.rs/crate/wasmtime-cli/45.0.1/source/docs/WASI-api.md)
- [Bytecode Alliance のプロジェクト一覧](https://bytecodealliance.org/projects)
- [wasmtime（PyPI）](https://pypi.org/project/wasmtime)
- [wasmtime-go: components support（Zulip のアーカイブ）](https://bytecodealliance.github.io/zulip-archive/stream/217126-wasmtime/topic/wasmtime-go.20components.20support.html)
- [Wasmtime（NuGet）](https://nubrowse.com/packages/Wasmtime)
- [.NET 10: No WASI](https://henrikrxn.github.io/blog/Wasi-dotnet-10)
- [Component Model の資料: Go Tooling](https://component-model.bytecodealliance.org/language-support/go.html)
- [Component Model の資料: TinyGo](https://component-model.bytecodealliance.org/language-support/building-a-simple-component/tinygo.html)
- [Compile Go directly to WebAssembly components with TinyGo and WASI P2（wasmCloud）](https://wasmcloud.website.cncfstack.com/blog/compile-go-directly-to-webassembly-components-with-tinygo-and-wasi-p2)
- [Golang for WebAssembly can now work like it should（The New Stack）](https://thenewstack.io/golang-for-webassembly-can-now-work-like-it-should/)
- [componentize-py（GitHub）](https://github.com/bytecodealliance/componentize-py/)
- [Golem: Python のコンポーネントのビルド](https://learn.golem.cloud/python-language-guide/building-components)
- [ComponentizeJS（GitHub）](https://github.com/bytecodealliance/componentizejs)
- [StarlingMonkey（awesome.ecosyste.ms）](https://awesome.ecosyste.ms/projects/github.com%2Fbytecodealliance%2FStarlingMonkey)
