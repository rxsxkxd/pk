# ssm-setup — SSM を使えるようにする道具（フェーズ 1）

> 状態: コマンド（本体の `ssm-role`・`ssm-check`・`ssm-connect-check`・`ssm-agent` と、バックアップの `backup`・`check`）がそろっている。`ssm-agent` の SSH の部分は手元の再現の環境で確かめた。実際の AWS ではまだ動かしていない。

## 役割

今の環境（Amazon Linux 2）の運用中のインスタンスを、**SSM（Session Manager・Run Command）で入れる状態にする**。ほとんどの台は SSM Agent が入って動いていて、IAM ロール（インスタンスプロファイル）がないだけと見込んでいる。そのため、まず未設定の台に SSM 用のインスタンスプロファイルを関連付けて、SSM で実際に入れるかを確かめ、**SSM Agent で直る見込みの台だけ**にバックアップを取ってから、SSH で SSM Agent を入れて有効にする。それ以外の入れない台（止まっている、ロールに権限がない、Online なのにつながらない、など）は、理由を表示して手で直す。作業者の PC で動き、AWS CLI のコマンドと SSH を使う。

80・443 番を国内だけに絞る設定（iptables ＋ ipset）を入れる [port-guard-rollout](../port-guard-rollout/README.md) の**前のフェーズ**として、作業を完全に分けている。port-guard-rollout は、このフェーズの `ssm-connect-check` で「入れる」になった台を、SSM で操作する。

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [手順](./steps.md) | **作業の手順の正本**。フェーズの分け方、流れ、各コマンドの使い方、バックアップの確認、元に戻す方法、手元での試し方 |
| [踏み台サーバーと AWS CLI で SSM を使えるようにするコマンド](./bastion-commands.md) | port-guard-rollout の [踏み台サーバーから入れるコマンド](../port-guard-rollout/bastion-install-commands.md) と同じ形。ステップごとに、実行するコマンドを並べただけのファイル（AWS の API は `aws/`、SSM Agent の確認と導入は踏み台サーバーからの SSH で `command/`）。流れは道具と同じ（ロールの状態 → 付与 → 権限の確認 → 登録 → 実接続。Online にならない台だけバックアップ → SSM Agent） |
| [ssm-role・ssm-check の処理の流れ（sh 版・Ruby 版）](./role-check-flow.md) | 機能を絞った sh 版（`sh/`。50 行以内）と Ruby 版（`rb/`。rubocop の既定に合わせた）の、コマンドの中の処理の流れ（Mermaid）と、Python 版との違い。未検証 |

## 流れ

流れの図は [手順の「流れ」](./steps.md#流れ)（Mermaid）にある。SVG 版: [SSM の有効化の流れ](images/flow-ssm-setup.svg)、[IAM ロールとインスタンスプロファイルの関係](images/iam-instance-profile.svg)。

コマンドは `ssm-role`（IAM ロールが未設定の台に SSM 用のインスタンスプロファイルを関連付ける）→ `ssm-check --ok-out enabled.txt --ng-out ng.txt`（権限と AWS の上の状態だけを見て、「SSM 有効」「SSM Agent で直す」「手で直す」に分けて一覧を書き出す。インスタンスには何も送らない）→ `ssm-connect-check --ok-out ok.txt < enabled.txt`（事前の確認をせず、`echo` を流して実際に入れるかだけを見る）→ SSM Agent で直す台だけ `backup` → `check`（補助）→ `ssm-agent`（SSM Agent がない・止まっている台）→ もう一度 `ssm-check` → `ssm-connect-check --ok-out ok2.txt` の順に使う。`ok.txt` と `ok2.txt` の台がフェーズ 2 の対象になる。

バックアップ（`backup`・`check`）は本体と分けて、別のコマンド `python3 -m ssm_setup_backup` にしている。

```bash
cd ssm-setup/py
python3 -m ssm_setup --help             # 本体（ssm-role・ssm-check・ssm-connect-check・ssm-agent）
python3 -m ssm_setup <コマンド> --help
python3 -m ssm_setup_backup --help      # バックアップ（backup・check）
python3 -m ssm_setup_backup <コマンド> --help
```

## 実装の方針

port-guard-rollout と同じ方針にしている。

| 項目 | 内容 |
|---|---|
| 言語 | **Python**（標準のライブラリだけを使う）。AMI 公開パイプラインの決定事項 D10（作業者の PC で動く道具は Go）は、この暫定対応の道具には当てはめない |
| AWS の操作 | **作業者の PC に入っている AWS CLI のコマンドを呼ぶ**（AWS SDK は使わない） |
| インスタンスでの実行 | SSH（`ssm-agent` だけ）。`ssm-connect-check` の接続の確認は Session Manager か Run Command |
| port-guard-rollout との共通の部品 | `py/ssm_setup/` の `awscli.py`・`targets.py`・`console.py`・`ssh.py`・`runcommand.py`・`flow.py` と、`py/ssm_setup_backup/` の `backups.py`・`backup.py`・`check.py` は、port-guard-rollout の同じ名前のファイルの写し（フォルダをまたいで読み込まないため）。違いは、バックアップのタグ `Purpose`（`ssm-setup-backup`）と AMI の名前（`before-ssm-setup`）、`awscli.py` の `run_text`（`ssm-check` の Session Manager で使う）。片方を直したら、もう片方も要るかを見る |

## テスト

AWS・SSH・SSM には接続せず、偽物で確かめる。

```bash
cd ssm-setup/py
python3 -m unittest discover -s tests
```

## フォルダの中身

| フォルダ | 内容 |
|---|---|
| `py/ssm_setup/` | Python 版の道具の本体。`ssm_role.py`（IAM ロールの関連付け）、`ssm_agent.py`（SSM Agent の導入）、`ssm_check.py`（権限と AWS の上の状態で SSM 有効かの確認）、`ssm_connect_check.py`（実接続の確認）、`flow.py`（コマンドの共通の流れ。各コマンドは「確かめる（plan）」と「行う（apply）」だけを書き、入力・前提の確認・表示・確認・1 台ごとの失敗の扱い・終了コードはここで行う。`ssm-role`・`ssm-agent`・`backup` が使う。`ssm-check` は設定を変えないので使わない）、`__main__.py`（コマンドの入り口）と、上の共通の部品 |
| `py/ssm_setup_backup/` | バックアップ（Python 版。`python3 -m ssm_setup_backup`）。`backup.py`（AMI を作る）、`check.py`（バックアップがあるかを確かめるだけ）、`backups.py`（タグの決まりと、`ssm-agent` が操作の前に行う確認）、`__main__.py`（コマンドの入り口）。AWS CLI の呼び出しなどは `ssm_setup/` の部品を使い、`ssm_setup/` からは操作の前の確認（`backups.py`）だけを使う |
| `py/ssm_setup/remote/` | インスタンスに送るもの。`agent-check.sh`・`agent-install.sh`（SSM Agent の確認と導入） |
| `images/` | 流れの図 `flow-ssm-setup.svg`（作るスクリプトは `make_flow_svg.py`）、IAM ロールとインスタンスプロファイルの関係の図 `iam-instance-profile.svg`（`make_iam_svg.py`） |
| `py/tests/` | Python 版のテスト（標準の `unittest`） |
| `sh/` | sh 版（`ssm-role.sh`・`ssm-check.sh`・`lib.sh`。機能を絞って 50 行以内）。[処理の流れ](./role-check-flow.md) |
| `rb/` | Ruby 版（`ssm_role.rb`・`ssm_check.rb`・`ssm_connect_check.rb`・`lib.rb`。標準のライブラリだけ。書き方の確認の rubocop だけ `Gemfile` で入れる）。[処理の流れ](./role-check-flow.md) |

手元の再現の環境（今の構成に近いインスタンスの Docker の定義）は [port-guard-rollout の `al2-instance/`](../port-guard-rollout/al2-instance/README.md) を使う。

## 関連ドキュメント

- [port-guard-rollout（フェーズ 2）](../port-guard-rollout/README.md)
- [検討の経緯: 設計（note）](../notes/ec2-operations/access-restriction-rollout-script-design.md)（「SSM の準備」の検討の記録）
- [SSM Session Manager の運用（note）](../notes/ec2-operations/ssm-session-manager-operations.md)
