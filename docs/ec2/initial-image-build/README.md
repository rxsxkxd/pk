# initial-image-build — 起点: ソースからの最初のイメージの作成

> 状態: **未着手**（フェーズの番号は未定）。このフォルダには役割と検討の入口だけを置いている。全体の中での位置付けは [全体像](../README.md#全体像) を参照。

## 役割

アプリのソースしかない状況から**最初のイメージ**を作り、そこから AMI の作成元になる**リリース用インスタンス**を起動する。全体のフローのうち、手順 1・2 を担当する。

| # | フローの手順 | 段階・フォルダ |
|---|---|---|
| **1** | **ソースから最初のイメージ（OS・ミドルウェアなどの下回りとアプリ）を作る** | **起点: このフォルダ** |
| **2** | **最初のイメージから、リリース用インスタンスを起動する** | **起点: このフォルダ** |
| 3 | リリース用インスタンスでは、上物のアプリだけを新しいリリースバージョンにアップデートする | 前段: [`release-verification/`](../release-verification/README.md) |
| 4 | アップデートしたインスタンスをもとに、アプリのパッケージとして AMI と起動テンプレートを作る | 中段: [`ami-publish/`](../ami-publish/README.md) |
| 5 | 起動テンプレートを使って配布する | 後段: [`instance-provisioning/`](../instance-provisioning/README.md) |

- 手順 1・2 を行うのは、最初の 1 回と、**下回り（OS・ミドルウェア）を作り直すとき**だけ。リリースのたびに繰り返すのは手順 3〜5 で、そこでは上物のアプリだけを入れ替える
- そのため、最初のイメージには「リリースのたびには変えない下回り」を入れる。アプリは、リリース用インスタンスを動かせる状態にするために入れる（以降の版は手順 3 で更新する）

## 方式の候補（未決定）

| 方式 | 作るもの | 手順 2（リリース用インスタンスの起動）とのつながり |
|---|---|---|
| EC2 Image Builder | AMI | 作った AMI からそのままリリース用インスタンスを起動できる |
| Docker | コンテナイメージ | **EC2 はコンテナイメージから直接起動できない**。手順 2 につなぐには、Dockerfile を下回りの構成の定義・検証（手元で同じ構成を再現して確かめる）に使い、AMI は別の方法で作る、などの組み合わせが必要 |

## 決めること

- 方式（EC2 Image Builder にするか、Docker をどう組み合わせるか）
- 下回りとして最初のイメージに入れるものと、手順 3 で更新する上物（アプリ）の境目
- 起動時に入れるもの（設定値、シークレット、サーバーごとの値）の分け方
- 手順 2 の起動のしかた（誰が、何で起動するか。リリース用インスタンスの IAM ロールのスタックなど、中段の前提との合わせ方）
- 下回りを作り直したときの、リリース用インスタンスの入れ替え方

## 関連ドキュメント

- [作業計画](./work-plan.md)（用意する成果 R1〜R7 と、作業 W0〜W6）
- [土台の構成: Amazon Linux 2023 と Ruby / Rails](./base-image-composition.md)（OS とミドルウェアについて決めたことと、層の分け方）
- [更新のサイクル](./update-cycles.md)（AL2023 の更新、ライブパッチ、土台の作り直し、アプリのリリースの関係を図で示したもの）
- [土台の構成（アプリが Go の場合）: Amazon Linux 2023 と Go](./base-image-composition-go.md)（比較のための検討。Ruby / Rails の場合との違いと、構成全体への影響）
- [EC2 Image Builder の仕組み（AMI ができるまで）](./ec2-image-builder-how-it-works.md)
- [Docker の定義: Amazon Linux 2023 と Ruby 3.4](./docker/al2023-ruby3.4/README.md)（Docker の方式で下回りを定義・再現するもの。Ruby 3.4 の最新のパッチバージョンを ruby-build で入れる）
- [EC2 Image Builder の定義: Amazon Linux 2023 と Ruby 3.4（下書き・未検証）](./image-builder/al2023-ruby3.4/README.md)（同じ土台の AMI を Image Builder で作る CloudFormation のテンプレートと、Docker の定義との違い）
- [Docker の定義: AL2023 のパッケージ ruby3.4](./docker/al2023-ruby3.4-dnf/README.md) と [EC2 Image Builder の定義: AL2023 のパッケージ ruby3.4（下書き・未検証）](./image-builder/al2023-ruby3.4-dnf/README.md)（比較のため、`dnf install ruby3.4` で Ruby 3.4.8 を入れる定義。土台の構成の Ruby の入れ方 A）
- [Docker の定義: mise のビルド済みの Ruby 3 系の最新（試すためのもの・未検証）](./docker/al2023-ruby3.4-mise/README.md)（mise で jdx/ruby のビルド済みの Ruby を取得する。3 つの入れ方の比較）
- [EC2 Image Builder の定義: mise のビルド済みの Ruby 3 系の最新（下書き・未検証・保留）](./image-builder/al2023-ruby3.4-mise/README.md)（同じ入れ方で土台の AMI を作る定義。Docker の定義を試した後に検証する）
- [メモ: AMI 作成に EC2 Image Builder を使う案（未採用）](../notes/ami-publish/ami-build-image-builder-options-memo.md)（中段の AMI の作成を置き換える案として検討したもの。Image Builder の特徴と課題）
- [開発手順: AMI から開発用のインスタンスを起動し、ファイルを S3 に集める](../instance-provisioning/development-collect-files-from-ami.md)（既存の AMI から設定ファイルを集める手順。最初のイメージに入れる内容の調査に使える）
