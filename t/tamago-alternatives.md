# TamaGoの競合・代替技術

作成日: 2026-11-11

Goでベアメタルを動かすという観点では、TinyGoとEmbedded Goが近い比較対象になる。Goアプリを専用機として運用する用途ではgokrazy、軽量なVMとして動かす用途ではUnikraftやNanosも候補になる。

Python・Rubyでは、組み込み向けの言語ランタイムと、通常の言語処理系を専用カーネル上で動かす方式に分けて比較する。

## 主な比較対象

| 選択肢 | 主な狙い | TamaGoとの違い |
| --- | --- | --- |
| TamaGo | 標準Goを土台に、OSなしでアプリを動かす | 改変したGoツールチェーンと、GoのCPU・SoC・ボード対応を組み合わせる |
| TinyGo | 小さなマイコンなどでGoを動かす | LLVMベースの別コンパイラ。小さいメモリ向けだが、標準Goとの互換性に差がある |
| Embedded Go | マイコン向けに標準Goを拡張する | 標準Goコンパイラを改変する点が近い。対応ハードやランタイムの設計が異なる |
| gokrazy | Goアプリを専用機として運用する | Linuxカーネルを残し、Go中心の小さなユーザーランドを使う |
| Unikraft | アプリ専用の軽量な実行イメージを作る | Linuxのシステムコール互換性を提供し、既存アプリを動かす方向 |
| Nanos＋OPS | Go・Python・RubyなどのアプリをunikernelとしてVMで動かす | 既存のLinux向け実行ファイルや言語処理系を専用カーネルで動かす。OPSは構築・実行用のツール |
| Rust＋Embassy | Rustで組み込み機器を開発する | 言語は変わるが、ドライバ・タイマー・非同期処理を組み合わせたベアメタル開発で比較対象になる |
| MicroPython / CircuitPython | Pythonでマイコンなどを制御する | Cで実装された言語ランタイム上でPythonコードを実行。OS・RTOSの有無はポートによる |
| mruby | Ruby処理系をアプリやファームウェアに組み込む | 軽量なRuby VMを組み込むための基盤。ボード対応やネットワーク機能などは別途必要 |
| mruby/c | 小さなマイコンでRubyのバイトコードを実行する | メモリ消費を抑えたVM。クラスライブラリは限定的 |
| PicoRuby | Rubyでマイコン上の機器制御やスクリプト実行を行う | Ruby VMに周辺機能を組み合わせる。Cの実行基盤・SDKへの依存がある |

各方式の位置づけは、[TamaGo FAQ](https://github.com/usbarmory/tamago/wiki/Frequently-Asked-Questions-%28FAQ%29)、[TinyGoのマイコン向け設計](https://tinygo.org/docs/concepts/compiler-internals/microcontrollers/)、[Embedded Go](https://embeddedgo.github.io/)、[gokrazy](https://gokrazy.org/)、[Unikraftの互換性方針](https://unikraft.org/docs/concepts/compatibility)、[OPSの概要](https://docs.ops.city/ops)、[Embassy](https://github.com/embassy-rs/embassy)を参照。

## Goでベアメタルを動かす場合

TamaGo、TinyGo、Embedded Goは、GoでOSなしの実行環境を作る点で比較できる。ただし、対応ボードと標準Goとの互換性はそれぞれ確認する必要がある。

TamaGoは標準Goのランタイムやライブラリの再利用を重視している。TinyGoはマイコンなどの制約に合わせたコンパイラとランタイムを持つ。TinyGoにもgoroutineやGCはあるが、reflectionや標準ライブラリなどには互換性上の制約がある。[TamaGo FAQ](https://github.com/usbarmory/tamago/wiki/Frequently-Asked-Questions-%28FAQ%29)、[TinyGoの言語対応](https://tinygo.org/docs/reference/lang-support/)

Embedded Goも標準Goを拡張する方式を採用している。採用候補にする際は、対象ボード、利用するGoのバージョン、必要な周辺機器の対応状況を確認する。[Embedded Goの導入案内](https://embeddedgo.github.io/getting_started)

## Pythonで近いもの

### MicroPython

マイコン向けのPython実装。機器上のインタープリターとランタイムを通して、PythonでGPIO・通信・各種処理を扱う。新しいハードへの移植では、起動処理、CPU初期化、基本ドライバ、ボード設定などを用意する。実行基盤はCで実装されている。[公式の移植ガイド](https://docs.micropython.org/en/latest/develop/porting.html)

Pythonの構文やライブラリにはCPythonとの違いがあるため、通常のPythonパッケージがそのまま動くとは限らない。[CPythonとの差分](https://docs.micropython.org/en/latest/genrst/index.html)

「MicroPythonを使う」と「OSなしで動かす」も別の条件。例えばESP32ポートはFreeRTOSベースのESP-IDF上で動く。OS・RTOSへの依存は、採用するポートごとに確認する。[ESP32ポートの説明](https://docs.micropython.org/en/latest/esp32/general.html)

### CircuitPython

MicroPythonを基にした、機器制御や開発の始めやすさを重視するPython実装。対応ボード上の `code.py` を編集して実行する開発体験と、周辺機器向けライブラリが特徴。[公式ドキュメント](https://docs.circuitpython.org/en/latest/docs/index.html)

Raspberry Piの対応ボードには、Linuxを入れずにCircuitPythonを起動する `broadcom` ポートがある。これはRaspberry Pi OS上のCPythonからBlinkaを使う構成とは異なる。[公式のBare Metal / No OSガイド](https://learn.adafruit.com/circuitpython-on-raspberry-pi-bare-metal-no-os/overview)

対応ハードでの機器制御をPythonで行いたい場合の候補。通常のPythonサーバーをそのまま移すこととは分けて考える。

## Rubyで近いもの

### mruby

アプリケーションへリンクして組み込める、軽量なRuby実装。Rubyコードをバイトコードへコンパイルし、VMで実行する構成を取れる。実行基盤はCで、ファームウェアへ組み込む際は、必要なメモリ管理やハードウェアへの接続を用意する。[公式README](https://github.com/mruby/mruby)

mruby自体が、任意のボードを起動できる完成した実行環境を提供するわけではない。通常のCRubyやRubyGemsとの互換性も個別に確認する。

### mruby/c

小さなマイコン向けにメモリ消費を抑えた、別実装のmruby VM。公式READMEでも、クラスライブラリの制限と、実行速度よりサイズを重視する方針が示されている。[公式README](https://github.com/mrubyc/mrubyc)

`mrbc` で生成したバイトコードをVMで実行する。バイトコードをCの配列として実行ファイルへ組み込む方法や、タスクとして実行する方法がある。ハードへの移植では、VMとボード側の処理を接続する。[公式のビルド・実行説明](https://github.com/mrubyc/mrubyc/blob/master/doc/compile.md)

### PicoRuby

マイコン向けRuby実装で、Raspberry Pi Pico系列を参照ボードとしている。シェル環境のR2P2やキーボードファームウェアなどにも利用される。Cのライブラリや実行基盤への依存があり、TamaGoの「実行時のC依存をなくす」方針とは異なる。[公式README](https://github.com/picoruby/picoruby)

2026-11に確認したREADMEでは、4.x以降のmruby VM版をPicoRuby、mruby/c VM版をFemtoRubyと呼んでいる。古い説明と名称・VMの対応が異なる場合があるため、採用するバージョンの構成を確認する。

## Python・RubyのサーバーをVMで動かす場合

既存のPython・Rubyアプリを軽量なVMにまとめるなら、言語をマイコン向け実装へ移す方法に加え、通常の言語処理系をNanos上で動かす方式がある。

```text
Python / Rubyのアプリ
  ↓
Python / Rubyの言語処理系と必要なライブラリ
  ↓
専用カーネルのNanos
  ↓
QEMUなどの仮想マシン環境
```

OPSの公式サンプルには、[PythonのHello World・Flaskなど](https://github.com/nanovms/ops-examples/tree/master/python)と、[RubyのSinatra HTTPサーバー](https://github.com/nanovms/ops-examples/tree/master/ruby/02-http-hello-world)がある。これはTamaGoのように言語ランタイムを直接ハードへ適応する方式とは異なり、専用カーネルが実行基盤を提供する。

公式サンプルのランタイムや依存ライブラリには古いバージョンも含まれる。サンプルの存在を対応方式の参考にし、実際には使用したいバージョン、拡張モジュール、システムコール、ネットワーク機能で検証する。ここではPython・Ruby版サーバーの実行確認までは行っていない。

「Cでアプリを書かない」ことと「実行基盤からもC依存をなくす」ことは分けて比較する。MicroPython・CircuitPython・mruby系や、通常のPython・Ruby処理系を使う構成は、アプリをPython・Rubyで書けてもCの実行基盤への依存が残る。

## Python・Ruby系の「VMを組み込む」とは

MicroPython、CircuitPython、mruby、mruby/c、PicoRubyは、基本的には言語VMやインタープリターをファームウェアへ組み込み、その上でPython・Rubyのコードを実行する方式として捉えられる。

```text
Python / Rubyのアプリ（ソースやコンパイル済みバイトコード）
  ↓
言語VM・インタープリター・ランタイム
  ↓
ボード対応・ドライバ（ポートによってはRTOSなども利用）
  ↓
ハードウェア
```

言語処理系を実装したCのコード自体は、対象CPU向けの機械語へコンパイルして組み込む。Python・Rubyのアプリを、通常はその処理系が実行するという関係になる。

| 実装系 | 基本的な位置づけ |
| --- | --- |
| MicroPython | Pythonコンパイラ・VM・ランタイムと、各ボード向け機能を組み合わせる |
| CircuitPython | PythonのVM・ランタイムに、ファイル編集・再読み込みや機器制御の機能を組み合わせる |
| mruby | 他のアプリやファームウェアへリンクして組み込めるRuby処理系 |
| mruby/c | 主にホストでコンパイルしたRubyバイトコードを実行する小さなVM |
| PicoRuby | Ruby VMにコンパイラや機器向け機能を組み合わせる。VMの構成はバージョン・ビルド設定による |

MicroPythonには例外があり、対応するポート・構成では、関数に `@micropython.native` や `@micropython.viper` を指定して機械語を生成する方法もある。したがって、すべての処理が常にバイトコードの解釈実行になるとは限らない。ただし、この場合もオブジェクト管理などの実行基盤まで不要になるわけではない。[MicroPythonのコンパイラ](https://docs.micropython.org/en/latest/develop/compiler.html)、[Native / Viperの説明](https://docs.micropython.org/en/latest/reference/speed_python.html)

また、利用者が毎回CのファームウェアへVMを手作業で組み込む必要があるわけではない。MicroPythonやCircuitPythonなどの対応済みファームウェアでは、既に組み込まれた処理系へアプリを渡して使える。[MicroPythonの移植構成](https://docs.micropython.org/en/latest/develop/porting.html)、[CircuitPythonの配布・開発方法](https://docs.circuitpython.org/en/latest/docs/index.html)

ここでいうVMは、Python・Rubyの命令やオブジェクトを扱う「言語VM」。CPUや周辺機器を再現するQEMUのような「ハードウェアVM」とは役割が異なる。言語VMはベアメタル上にもOS上にも実装できる。

TamaGoにもGCやgoroutineを支えるGoランタイムはあるが、アプリのGoコードは基本的に対象CPUの機械語にコンパイルされる。「言語VMでバイトコードを実行するか」と「ランタイムがあるか」は別の軸になる。

## Linuxの機能をどこまで残すか

gokrazyはLinuxカーネルを使う。ファイルシステムやデバイスドライバなどのOS機能を利用しつつ、通常のLinuxディストリビューションより構成を小さくする方向になる。最小限のinit、更新、DHCP、NTPなどもgokrazyの構成に含まれる。[gokrazyの概要](https://gokrazy.org/)

UnikraftとNanosは、それぞれ専用の実行基盤を提供する。Linuxの互換APIを利用するアプリでも、必要なシステムコールや実行環境が対応しているかを確認する必要がある。Linux向けバイナリがすべて無条件に動くと考えず、対象アプリで検証する。[Unikraftの互換性](https://unikraft.org/docs/concepts/compatibility)、[Nanos FAQ](https://nanos.org/faq)

## LLVM・LLVM IRとベアメタル対応

LLVMを使うと、各言語のコンパイラから共通の最適化・機械語生成の基盤を利用できる。対象CPUのバックエンドがあれば、ベアメタル向け機械語を生成する土台になる。

```text
言語のソースコード
  → 言語のコンパイラ
  → LLVM IR
  → ARM・RISC-Vなどの機械語
```

ただし、LLVM IRを出力できることだけでは、OSなしの実行環境は完成しない。さらに次の要素が必要になる。

| 要素 | 用意する内容 |
| --- | --- |
| 起動・リンク | CPU初期化、メモリ配置、エントリーポイント、リンク設定 |
| 言語ランタイム | 使用する機能に応じたGC、メモリ確保、例外、並行処理など |
| コンパイラの補助処理 | CPU命令へ直接変換できない演算などのランタイム関数 |
| 外部機能への接続 | ファイル、時計、標準出力、ネットワーク、デバイス操作 |

例えば、IRに `malloc` やOSのシステムコールを呼ぶ処理があっても、LLVMが対象ハード向けの実装を自動で用意するわけではない。必要なライブラリと実行時の依存を移植・接続する。[Clangのツールチェーン](https://clang.llvm.org/docs/Toolchain.html)、[クロスコンパイルの説明](https://clang.llvm.org/docs/CrossCompilation.html)

既にLinux向けの前提で生成したIRを、ターゲット設定だけ変えても移植が完了するとは限らない。データ配置、ABI、依存する関数なども対象に合わせる。

TinyGoはLLVMにGo向けランタイムとボード対応を組み合わせた例。一方、TamaGoは標準Goコンパイラを改変する方式で、LLVMの利用はベアメタル実行の必須条件ではない。[TinyGo公式](https://tinygo.org/)、[TamaGo FAQ](https://github.com/usbarmory/tamago/wiki/Frequently-Asked-Questions-%28FAQ%29)

### LLVMを利用する代表的な処理系

LLVMは、複数の言語処理系がコード生成や最適化のために利用している。言語ごとに前段の解析・型検査・独自の中間表現を持ち、その後LLVM IRへ変換する構成も多い。

| 言語・処理系 | LLVMの利用方法 |
| --- | --- |
| [Swift](https://www.swift.org/documentation/swift-compiler/) | Swift独自の中間表現SILをLLVM IRへ変換し、最適化・機械語生成を行う |
| [Rust / rustc](https://rustc-dev-guide.rust-lang.org/backend/codegen.html) | 主なコード生成バックエンドとしてLLVMを利用。他のバックエンドも存在する |
| [C・C++ / Clang](https://clang.llvm.org/docs/Toolchain.html) | LLVMを使う代表的なコンパイラ |
| [Julia](https://docs.julialang.org/en/v1/devdocs/llvm/) | LLVM IRへの変換と、JITコンパイルなどに利用 |
| [Kotlin/Native](https://kotlinlang.org/docs/native-overview.html) | JVMを使わず、LLVMベースのバックエンドでネイティブコードを生成 |
| [Go / TinyGo](https://tinygo.org/) | LLVMを使うGoの別実装。標準Goコンパイラとは異なる |
| [Python / Codon](https://docs.exaloop.io/developers/compilation/) | 独自のフロントエンドとIRを経てLLVMで機械語を生成。AOTが基本でJITも利用可能 |
| [Python / Numba](https://numba.readthedocs.io/en/0.67.0/developer/architecture.html) | 対象のPython関数を解析し、LLVM IRを生成してJITコンパイル |

### PythonのLLVM利用例：CodonとNumba

Codonは、Pythonコードから独立したネイティブ実行ファイルなどを生成するコンパイラ寄りの選択肢。LLVM IRの出力にも対応する。一方でCPythonの完全な置き換えではなく、一部の動的な振る舞いやライブラリの扱いが異なる。[Codonの概要](https://docs.exaloop.io/)、[出力形式とLLVM IRの生成](https://docs.exaloop.io/start/usage/)

Numbaは、既存のPythonアプリの中で対象関数をJITコンパイルする使い方が中心。特にNumPy配列や数値計算・ループを含む処理を対象にする。Pythonアプリ全体を自動でベアメタル向け実行ファイルへ変換する仕組みではない。[Numbaの導入説明](https://numba.readthedocs.io/en/stable/user/5minguide.html)

どちらも、LLVMで機械語を生成できることと、ランタイム・標準ライブラリ・OS依存を解消することは別。ここではLLVMの採用例として挙げており、今回のボードやTamaGo環境への移植は未検証。

### RubyのLLVM利用例：Rubinius

Rubiniusは、LLVMを利用する機械語コンパイラを備えたRuby系の実行環境。VM、GC、スレッド、ファイルなどの仕組みも持ち、macOSやUnix/Linux上での実行を前提とする。[公式README](https://github.com/rubinius/rubinius)

このため、LLVMを採用したRuby実装の例にはなるが、mruby系の組み込み用VMや、TamaGoのようにボード対応を組み合わせた実行環境とは用途が異なる。採用時にはRubyとの互換性と保守状況も確認する。

### ベアメタル用途での見方

LLVMを使う処理系でも、組み込み向けの移植範囲は異なる。Swiftには [Embedded Swift](https://www.swift.org/get-started/embedded/)、Rustには組み込み向けの環境、TinyGoにはマイコン向けの対応がある。一方、JuliaやNumbaなどをLLVM採用だけを理由に同じ条件の候補と扱うことはできない。

対象ハードの起動、必要な言語機能、メモリ管理、ライブラリ、外部I/Oまでを含めて、実行環境が揃うかを確認する。

## WebAssemblyとの関係

WebAssembly（Wasm）は、異なる環境へ配布して実行するためのコード形式と実行モデル。LLVM IRと同じものではないが、LLVMの出力先としてWasmを生成することはできる。

| 技術 | 主な役割 |
| --- | --- |
| LLVM IR | コンパイラ内部で最適化・コード生成に使う中間表現 |
| WebAssembly | 異なるCPU・環境へ配布できる、移植可能なコード形式と実行モデル |
| Wasmランタイム | Wasmを読み込み、解釈実行・JIT・AOTなどで実行する基盤 |
| WASI / 独自ホストAPI | 時計・ファイル・通信など、実行環境の機能を利用するための窓口 |

LLVM IRはターゲット依存の情報を含み得るため、そのまま共通の配布形式として扱う前提にはしない。Wasmは移植可能な実行形式として設計されている。[WebAssembly公式FAQ](https://webassembly.org/docs/faq/)

Wasmはブラウザ専用ではなく、サーバーや組み込みでも利用できる。Wasmのコア仕様自体にはファイルシステムやハードウェアドライバはなく、ホストから提供されるAPIを呼んで利用する。[WebAssemblyの移植性とAPI](https://webassembly.org/docs/portability/)

WASIはそうしたAPIの標準化を行う。実際に使える機能は、WASIのバージョン、ランタイムの対応、ホストが許可する機能によって変わる。WASIを採用しても、下位のストレージやネットワーク実装が自動で用意されるわけではない。[WASI公式](https://wasi.dev/)

### TamaGoとWasmを組み合わせる構成案

```text
各言語で書いた処理をWasmとして配布
  ↓
TamaGoへ組み込んだWasmランタイム
  ↓
ホストAPI（必要な機能を限定して公開）
  ↓
TamaGoのネットワーク・時計・ハードウェア対応
  ↓
ハードウェア（またはQEMUが再現するボード）
```

この構成では、ハードウェアや通信の管理をTamaGoに置き、更新・差し替えたい業務処理をWasm側へ分離できる。提供するAPIと利用するWasm機能を揃えれば、複数言語・複数実行環境で同じ処理を共有しやすくなる。

ただし、採用するWasmランタイムのOS依存を解消し、TamaGo上で実行できるようにする作業と、ホストAPIへの接続が必要。ランタイムの移植と各モジュールの互換性は別途検証する。これは今回の環境への拡張案であり、現在のTamaGoデモには未実装。

組み込み向けのランタイムにはWAMRがあり、解釈実行やAOTなどに対応する。ただし、組み込み向けであることが、そのままTamaGo対応を意味するわけではない。[WAMR公式](https://github.com/wasm-micro-runtime/wasm-micro-runtime)

Wasmを導入すると、移植・差し替え・アクセス範囲の制御を設計しやすくなる一方、ランタイムとそのメモリ・処理コストが加わる。AOTを使う場合は、一般にコンパイル後の成果物を対象CPUやランタイムに合わせて用意する。

## 今回の目的に照らした選び方

以下は各プロジェクトの方針を踏まえた、この検討での判断軸。

| 優先すること | 最初に比較する候補 |
| --- | --- |
| 標準Goの資産を活用し、ゲストOSを外したい | TamaGo |
| 小さなマイコンでセンサーや周辺機器を扱いたい | TinyGo、Embedded Go、Rust＋Embassy |
| LinuxのドライバやOS機能を使い、Goの専用機を作りたい | gokrazy |
| 既存のGoサーバーを軽量なVMイメージにまとめたい | Unikraft、Nanos＋OPS |
| Pythonで対応ボードの機器制御を行いたい | MicroPython、CircuitPython |
| Rubyで対応ボードの機器制御を行いたい | PicoRuby、mruby/c。独自に組み込む基盤としてmruby |
| Python・Rubyのサーバーを専用VMへまとめたい | Nanos＋OPS。言語処理系と依存ライブラリの対応を個別確認 |

今回のHTTPS echoサーバーを専用機として育てるなら、まずTamaGoとgokrazyを比べると、OSの有無による負担と利点を整理しやすい。ファイルの永続保存、時刻同期、ログ回収、アプリ更新を、それぞれ誰が提供するかを比較する。

VM上でのサーバー運用が主目的になれば、UnikraftやNanosも比較対象に加える。小さなマイコンでの機器制御が主目的になれば、TinyGoやEmbedded Go、Rust系の環境を優先して確認する。

## 採用前に確認する項目

- 対象CPU・ボード・仮想マシンで動かせるか。
- 必要なRAM・ストレージと周辺機器の対応があるか。
- Goパッケージ、Pythonパッケージ、Rubyのgemが、Cgo・ネイティブ拡張・OS固有機能に依存していないか。
- ファイル保存、ネットワーク、時計、乱数、TLSをどこまで利用できるか。
- 更新、再起動、障害復旧、ログ回収をどう実装・運用するか。
- 必要な応答時間、消費メモリ、起動時間を実際のアプリで満たせるか。

この比較は設計方針の整理であり、性能の実測比較ではない。今回動作確認したのはTamaGo版のHello WorldとHTTPS echoサーバーで、他方式への移植・実行比較は未実施。
