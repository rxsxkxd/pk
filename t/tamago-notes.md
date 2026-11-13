# TamaGo 実行環境の検討メモ

作成日: 2026-11-11

## ここまでの話

- TamaGoは、OSを介さずGoアプリをハードウェア上で動かすためのフレームワーク。
- 改変したGoツールチェーン、Goランタイム、対象ボードの初期化・ドライバを使う。
- goroutineや標準ライブラリを活用できる。ただしCgoやOS固有機能には制限がある。
- 実機なしで開発・動作確認するため、QEMUを使った実行環境を作りたい。
- ビルドツールとQEMUをコンテナにまとめる案を検討した。

## QEMUとKVMの整理

QEMUはCPU・メモリ・周辺機器を含む仮想マシンを提供する。KVMはLinuxのCPU仮想化機能で、QEMUと組み合わせて使える。

| 構成 | 特徴 | 今回の位置づけ |
| --- | --- | --- |
| QEMU＋TCG | CPU命令をソフトウェアで変換。異なるCPUアーキテクチャも実行できる | 最初の機能検証に使う候補 |
| QEMU＋KVM | CPUの仮想化機能を利用。基本的にホストと同系統のCPU向け | Linux環境で高速実行が必要になった場合に検討 |

手元はApple SiliconのMac。コンテナ内でKVMを使うには、コンテナ用Linux VM内でもKVMが利用できる必要がある。まずTCGを使う構成なら、その条件に依存せず始められる。

## 今回の構成案

**QEMUが再現するハードウェア上に、ゲストOSを挟まずTamaGoアプリを直接起動する。** TamaGoのGoランタイムもアプリに組み込まれる。

```text
QEMUが再現するCPU・メモリ・周辺機器
└─ TamaGoアプリ（Goランタイム・ボード対応を含む）
```

QEMU自体の配置は別の選択になる。

- Mac上に直接配置する。
- コンテナ内にビルドツールと一緒に配置する。

コンテナを使う場合の全体像:

```text
Mac（Apple Silicon）
└─ コンテナ用Linux VM
   └─ コンテナ（ビルドツール＋QEMU）
      └─ エミュレートしたハードウェア
         └─ TamaGoアプリ
```

外側のLinuxはコンテナを動かすためのもの。QEMU内でTamaGo用のLinuxを起動する必要はない。

## 次に決めること

- QEMUをMacに直接置くか、コンテナにまとめるか。
- エミュレートするボード。公式サンプルが対応するARMの `mcimx6ul-evk` が候補。
- 最初に確認する機能。まず起動・シリアル出力、その後goroutineや通信を確認する想定。

TamaGo側のボード対応とQEMUのマシンモデルを合わせる必要がある。エミュレーターで確認できる周辺機器には範囲があり、実機の処理時間や機器固有の挙動は実機で確認する。

現時点では構成の検討まで。Dockerfileの作成、TamaGoのビルド、QEMUでの起動確認は未実施。

## 参考

- [TamaGo](https://github.com/usbarmory/tamago)
- [TamaGo公式サンプル](https://github.com/usbarmory/tamago-example)
- [TamaGoの互換性・制限](https://github.com/usbarmory/tamago/wiki/Compatibility)
- [QEMUの概要・アクセラレーター](https://www.qemu.org/docs/master/system/introduction.html)
- [QEMUのARMボード選択](https://www.qemu.org/docs/master/system/target-arm.html)
- [KVM API](https://docs.kernel.org/virt/kvm/api.html)
