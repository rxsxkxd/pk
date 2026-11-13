# TamaGo 実機候補メモ

作成日: 2026-11-12

`tamago-lab/` の実装（Hello World と HTTPS echo）を、QEMU ではなく実機で動かす場合の候補を整理する。

## 用語

| 用語 | 指すもの |
| --- | --- |
| QEMU版ボード | QEMU のマシンモデル `mcimx6ul-evk`（i.MX6UL 評価ボードを模したもの）。`tamago-lab/` が現在動いている環境 |
| 実機 | 物理的なボード。この文書で候補として挙げるもの |
| ボード対応パッケージ | TamaGo の `board/...` 以下のパッケージ。ボードの初期化・周辺機器の設定を持つ |

## 結論

**MCIMX6ULL-EVK（NXP の i.MX6ULL 評価ボード）が最有力。** `tamago-lab/internal/platform/platform.go` が読み込んでいるボード対応パッケージ `board/nxp/mx6ullevk` はこのボード用で、`soc/nxp/imx6ul` の ENET1・UART もそのまま使える。QEMU版ボードは同じ系統の i.MX6UL 版を模しているため、構成が最も近い。

## 候補の比較

| 実機 | SoC | ボード対応パッケージ | 今のコードとの近さ | 備考 |
| --- | --- | --- | --- | --- |
| **MCIMX6ULL-EVK** | NXP i.MX6ULL | `board/nxp/mx6ullevk` | ◎ 同じパッケージ | Ethernet 2 口。HTTPS echo まで狙える。RAM 512 MiB（0x80000000〜）で今のメモリ配置と同じ |
| USB armory Mk II LAN | NXP i.MX6UL / i.MX6ULL | `board/usbarmory/mk2` | ○ 同系統の SoC | Ethernet あり。ボード初期化の差し替えが必要 |
| USB armory Mk II | NXP i.MX6ULZ | `board/usbarmory/mk2` | △ | Ethernet なし。通信は USB 経由のネットワークで別実装。Hello World 向き |
| Raspberry Pi Zero / 1 / 2 | Broadcom BCM2835 / BCM2836 | `board/raspberrypi` | × | SoC が別系統。ボード対応・ネットワーク・メモリ配置を作り直す |
| NuMaker-IIoT-NUC980G2 | Nuvoton NUC980 | `board/nuvoton/nuc980iiot` | × | SoC が別系統 |
| 8MPLUSLPD4-EVK など | NXP i.MX8M Plus ほか | `board/nxp/imx8mpevk` ほか | × | `GOARCH=arm64`。移植になる |

amd64 の Firecracker・Cloud Hypervisor・QEMU microvm・Google Compute Engine にも対応があるが、いずれも仮想マシンで実機ではない。

## 実機に移すときに変える箇所

今の実装は QEMU版ボード専用の作りを含み、そのままでは実機で動かない。

1. **終了処理** — `internal/platform/platform.go` の `Exit` は ARM semihosting（`SVC 0x123456`）で QEMU を終了させる。デバッガ未接続の実機では例外になるか停止する。リセットか無限ループでの停止に替える。
2. **起動方法** — QEMU は `-kernel` で ELF を直接読み込むが、実機ではできない。U-Boot の `bootelf` で読み込むか、i.MX のブートヘッダー（DCD）付きイメージにして SD カードや USB（SDP）から起動する。公式サンプル `tamago-example` の Makefile にある `imx` ターゲットが参考になる。
3. **Ethernet の PHY と MAC アドレス** — QEMU版ボードでは PHY 初期化を意識していない。実機では PHY 設定とリンクアップ待ちを確認する。固定 MAC `1a:55:89:a2:69:41` も見直す。
4. **乱数と証明書** — QEMU版ボードの乱数は本番用ではない（`internal/echoserver/server.go` のコメントどおり）。実機では SoC のハードウェア乱数を使う。使える乱数源は SoC ごとに確認が要る。
5. **シリアルコンソール** — EVK では基板上の USB デバッグポートが UART1 になる（QEMU の `-serial stdio` に相当）。

## 未確認の点

- 候補の表は TamaGo リポジトリ README の対応表に基づく。各ボードで実際に何がテスト済みかは、各ボード対応パッケージの README で確認していない。
- 変更箇所 3（PHY）と 4（乱数源）について、MCIMX6ULL-EVK での正しい扱いは未調査。

## 次に決めること

- 実機を MCIMX6ULL-EVK にするか。
- QEMU版ボード用と実機用の差分をどう分けるか（例: `platform` をビルドタグで分ける）。
- 起動方法を U-Boot 経由にするか、ブートイメージを作るか。

## 評価ボード以外の候補（市販品・製品）

追記日: 2026-11-12

シンセサイザーやカメラなど、カスタムファームの対象になりやすい市販品も含めて探した。

### 探し方

- TamaGo が対応する SoC（i.MX6UL / ULL / ULZ、BCM2835 / BCM2836）を積んだ製品を探した。
- 市販品は中身の SoC が公表されないことが多い。そこで Linux 本家（mainline）のデバイスツリー `arch/arm/boot/dts/nxp/imx/` から、i.MX6UL / ULL / ULZ を使う**製品**のエントリーを拾った。mainline にデバイスツリーがある製品は、中身の構成が公開されていて、自作のコードを起動した実績があるものが多い。

### 市販の製品

| 製品 | 種類 | SoC | TamaGo との近さ | 根拠・注意 |
| --- | --- | --- | --- | --- |
| **UNI-T UTi260B** | 携帯型サーモグラフィカメラ（一般向けに販売） | i.MX6ULL | ○ SoC は対応。ボード対応パッケージは自作が必要 | mainline に `imx6ull-uti260b.dts` がある。Sebastian Reichel 氏がリバースエンジニアリングで作り、2024年に投稿した。発表タイトルは「Running FOSS on a Thermal Camera」（Embedded Recipes 2023）。**カスタムファームの実例があるカメラで、今回の条件に最も合う** |
| **USB armory Mk II** | セキュリティ用の USB ガジェット | i.MX6ULZ / ULL（LAN 版は i.MX6UL） | ◎ 公式に対応 | TamaGo 開発元の製品。ArmoredWitness（transparency.dev）はこのハード上の TamaGo 製ファームとして実際に使われている |
| Marantec maveo box | 車庫のドアを操作するスマートホーム用ゲートウェイ | i.MX6ULL（DH electronics の DHCOR モジュール） | △ SoC は対応 | mainline に `imx6ull-dhcor-maveo-box.dts`（メーカー自身が寄稿）。書き換えの事例は未確認 |
| BSH SMM M2 | BSH（Bosch・Siemens の家電）の家電内モジュール | i.MX6ULZ | △ SoC は対応。Ethernet なし | mainline に `imx6ulz-bsh-smm-m2.dts`。単体では手に入りにくい |
| JOZ Access Point | 業務用のアクセスポイント | i.MX6ULL | △ | mainline に `imx6ull-jozacp.dts` |
| chargebyte Tarragon | EV 充電器の制御ボード | i.MX6ULL | △ | mainline に `imx6ull-tarragon-*.dts`。業務用 |
| Protonic PRTI6G | 産業用ボード | i.MX6UL | △ | mainline に `imx6ul-prti6g.dts`。業務用 |

### Raspberry Pi 系の製品

| 製品 | 種類 | SoC | TamaGo で動くか | 根拠・注意 |
| --- | --- | --- | --- | --- |
| Raspberry Pi Zero / Zero W を使った自作機 | シンセ・カメラ | BCM2835 | ◎ SoC は公式に対応 | Circle というベアメタル環境での実例が多い。シンセの MiniSynth Pi・MiniDexed、カメラの rsta2/libcamera など。TamaGo 自体の実例ではない |
| Compute Module 1 を使った製品 | 産業用など | BCM2835 | ○ | CM1 は生産中だが新規設計には非推奨。具体的な製品名は見つからなかった |
| Korg の一部シンセ（CM3）、Organelle M（CM3+）、norns、Zynthian、MT32-Pi（Pi 3 / Zero 2 W 以降） | シンセ | BCM2837 以降 | × 未確認 | TamaGo の対応表にない SoC。Korg と Organelle M のファームは公開されていない |

### カスタムファームが盛んなシンセ・カメラの中身

シンセやカメラでカスタムファームが盛んな製品は、ほとんどが TamaGo の対象外の SoC を使っている。

| 製品 | カスタムファームの状況 | 中身 | TamaGo |
| --- | --- | --- | --- |
| Synthstrom Deluge（シンセ・シーケンサー） | 公式ファームを GPLv3 で公開。コミュニティ版あり | Renesas RZ/A1L（Cortex-A9、400 MHz、内蔵 SRAM 3 MB） | × 対応なし。Cortex-A なので移植の余地はある |
| Polyend Tracker / Tracker+ / Mini | 2026-11-02 にソースを公開（Community Edition） | 未確認（ファームは Intel HEX 形式で、マイコン系と思われる） | × 未確認 |
| Dirtywave M8 | ハードなしで動かす公式ファーム（Headless）を Teensy 向けに配布 | Teensy 4.1（i.MX RT1062、Cortex-M7） | × Cortex-M は対象外 |
| Akai MPC Live / X / One | 非公式ファーム Hakai で Force のソフトを起動できる | Linux 機。SoC は未確認（Rockchip 製と言われる） | × |
| ネットワークカメラ全般 | OpenIPC（148 チップ中 83 に導入可） | HiSilicon、Ingenic（MIPS）、SigmaStar、Anyka、Fullhan、Goke、Ambarella など | × |
| Canon のデジカメ（Magic Lantern・CHDK） | 非公式ファームが長く続いている | Canon 独自の DIGIC（ARM ベース）。今回の検索では裏付けを取れていない | × |

傾向:

- **小型のシンセ・グルーブボックス**は、STM32 や i.MX RT などの Cortex-M マイコンが多い。OS なしで動くが、TamaGo は Cortex-A（と amd64・RISC-V）向けなので対象外。
- **大きめのシンセ**は Linux が載る SoC（Raspberry Pi CM3 以降、Rockchip など）を使う。カスタムファームの多くは Linux の上の改造。
- **カメラ**は、映像処理を内蔵した専用 SoC（HiSilicon、Ingenic、Ambarella、Canon DIGIC など）を使う。i.MX6UL / ULL は映像処理が弱く、カメラにはあまり使われない。例外は、画素数の少ないサーモカメラの UNI-T UTi260B。

### 音源処理・画像処理に Cortex-A が必要か

**シンセの音源は Cortex-M で足りることが多い。カメラの画像処理は、Cortex-A でも Cortex-M でも CPU では足りず、専用回路でこなす。**

- **音源処理**: 48 kHz・ステレオなら、1 秒に約 10 万サンプルを計算すればよい。浮動小数点演算器と DSP 命令を持つ Cortex-M4F / M7（数百 MHz）で、複数の音を同時に鳴らせる。例は Dirtywave M8（i.MX RT1062、600 MHz）や STM32H7 系の音源。割り込みの応答が安定しているので、音切れを防ぐにはむしろ有利。
- **音源で Cortex-A が要る場面**: 次のような場合。
  - 数百 MB のサンプルを扱う（大容量の DRAM が要る）
  - 物理モデリングや畳み込みリバーブなど、重い処理を多数同時に鳴らす
  - Linux 上の既存ソフト（Pure Data、プラグインなど）を使う
  - 複雑な画面を出す

  Korg などが Raspberry Pi CM を選ぶのは、処理能力に加えて、Linux の資産を使えて開発しやすいからでもある。
- **画像処理**: 動画になると、Cortex-A の CPU でも追いつかない。たとえば 4K・30 fps は 1 秒に約 2.5 億画素ある。そのため、カメラ用 SoC は ISP（センサーの信号を画像にする回路）と H.264 / H.265 のエンコーダーを内蔵し、CPU は制御を受け持つだけ。CPU 自体は Cortex-A7 級や MIPS で足りる。i.MX6UL / ULL はカメラ入力（CSI）を持つが ISP とエンコーダーがないので、カメラ製品にはあまり使われない。例外は、画素数の少ないサーモカメラ（UTi260B は 256×192 程度）や、低解像度の画像認識（OpenMV は Cortex-M7）。
- **TamaGo への影響**:
  - 音源を作る場合、Go の GC による一時停止で音が途切れないよう、バッファを設計する必要がある。
  - カメラ用 SoC の ISP やエンコーダーは、ドライバーや資料が公開されていないことが多い。TamaGo から使うのは難しい。

### 対象外と分かったもの

- reMarkable・Kobo などの電子書籍端末: SoC が i.MX6SL / SLL / 7D など別系統。
- Sonos Connect: i.MX6SX（別系統）。
- 多くのシンセ（Teensy・STM32 系）: Cortex-M のマイコンで、TamaGo の対象外。
- NUC980 を使った一般向けの製品: 見つからなかった。

### 市販品で動かすときの注意

- **セキュアブートを確認する。** i.MX6 は HAB というセキュアブートの仕組みを持つ。製品で有効化（fuse で固定）されていると、署名のないファームは起動できない。まず USB の Serial Download（`imx_usb_loader` など）や UART で自作コードを起動できるかを確かめる。
- **ボード対応パッケージを自作する。** SoC が同じでも、メモリ容量・UART の位置・電源・周辺回路はボードごとに違う。mainline のデバイスツリーが、ピン配置や周辺機器を知る手がかりになる。
- **実機を壊すおそれがある。** 書き換えは保証外で、元のファームに戻せない場合がある。

### 未確認の点（市販品）

- UTi260B で、署名のないコードをどの経路で起動しているか（発表資料をまだ読んでいない）。
- maveo box などの製品で HAB が有効かどうか。
- Pi Zero 2 W・Pi 3 系（BCM2837）で、TamaGo の `pi2` パッケージが 32bit で動くかどうか。

## 参考

- [TamaGo（対応ボード一覧）](https://github.com/usbarmory/tamago)
- [Linux mainline の i.MX デバイスツリー](https://github.com/torvalds/linux/tree/master/arch/arm/boot/dts/nxp/imx)
- [UNI-T UTi260B 対応パッチ（v6）](https://lists.infradead.org/pipermail/linux-arm-kernel/2024-March/914693.html)
- [UNI-T UTi260B 対応パッチ（patchwork）](https://patchwork.kernel.org/project/imx/cover/20240325212402.150906-1-sre@kernel.org)
- [armored-witness-os](https://github.com/transparency-dev/armored-witness-os)
- [ArmoredWitness 発表資料](https://transparency.dev/pdfs/summit2024/tdev2024_%20ArmoredWitness.pdf)
- [Marantec maveo](https://www.marantec.com/en/help-and-advice/how-to-make-your-garage-door-opener-smart)
- [MiniSynth Pi](https://github.com/rsta2/minisynth)
- [MiniDexed（Hackaday）](https://hackaday.com/2023/05/07/an-rpi-powered-multi-dx7-tx816-style-synth)
- [rsta2/libcamera](https://github.com/rsta2/libcamera)
- [Compute Module 1](https://www.raspberrypi.com/products/compute-module-1)
- [Korg と Raspberry Pi](https://www.raspberrypi.com/news/electronic-music-icon-korg-makes-music-with-raspberry-pi/)
- [Organelle M（Engadget）](https://www.engadget.com/2019/07/16/organelle-m-portable-hackable-music-computer-hands-on/)
- [Sonos Connect (S15)](https://techinfodepot.shoutwiki.com/wiki/Sonos_Connect_(S15))
- [reMarkable imx_usb_loader](https://github.com/reMarkable/imx_usb_loader)
- [Deluge のオープンソース化（CDM）](https://cdm.link/synthstrom-deluge-open-source/)
- [DelugeFirmware](https://github.com/jtdaugherty/DelugeFirmware)
- [Polyend Tracker のカスタムファーム対応（Synthtopia）](https://www.synthtopia.com/?p=155829)
- [Dirtywave M8 Headless Firmware](https://github.com/Dirtywave/M8HeadlessFirmware)
- [OpenIPC 対応ハード](https://openipc.org/supported-hardware)
- [Akai MPC の非公式ファームの話題（MPC-Forums）](https://www.mpc-forums.com/viewtopic.php?p=1824334)

## 補足: Cortex-M で TamaGo の代わりになるもの

追記日: 2026-11-12

TamaGo は Cortex-A（と amd64・RISC-V）向けで、Cortex-M のマイコンでは動かない。Cortex-M を使う場合の候補を整理する。この表は手元の知識による整理で、各処理系の最新の対応状況は確認していない。

| 選択肢 | Cortex-M での位置づけ | 向いている用途 |
| --- | --- | --- |
| **TinyGo** | **Go で書くなら第一候補。** LLVM ベースの Go 処理系で、Cortex-M 向けが主戦場（STM32、nRF、RP2040 / RP2350、Teensy 4.x など） | Go の知識を活かした制御・通信・センサー処理 |
| Embedded Rust（Embassy、RTIC） | GC がなく、時間の読める処理を書きやすい | 音源など、時間の制約が厳しい処理 |
| C / C++（ベンダー SDK、Zephyr、FreeRTOS、libDaisy） | 事実上の標準。資料と実例が最も多い | 製品開発全般。シンセの多くもこれ |
| MicroPython / CircuitPython | 手軽だが遅い | 制御や試作。音源の中心の処理には不向き |
| mruby/c / PicoRuby | Ruby で書ける。メモリが小さくても動く | 小さな制御。音源には不向き |
| Wasm（WAMR などの組み込み向け実行環境） | 動かせるが、処理系の分だけ重くなる | アプリの差し替えや隔離が目的のとき |

- **Go で続けるなら TinyGo。** TamaGo とは別物で、通常の Go の標準ライブラリやランタイムを全部は使えない。その代わり、メモリが数百 KB のマイコンでも動く。
- **シンセの音源のように時間の制約が厳しいなら、Rust か C/C++。** TinyGo にも GC による一時停止があるので、音源の中心の処理では、メモリ確保をしない書き方が必要になる。

未確認の点:

- TinyGo の対応ボード一覧の最新版（Teensy 4.1 や STM32H7 への対応状況）。
- TinyGo で音源を書いた実例がどの程度あるか。
