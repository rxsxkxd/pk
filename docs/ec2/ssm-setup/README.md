# ssm-setup — SSM を使えるようにする道具（フェーズ 1）

> 状態: コマンド（`ssm-role`・`ssm-check`・`backup`・`backup-check`・`ssm-agent`）がそろっている。`ssm-agent` の SSH の部分は手元の再現の環境で確かめた。実際の AWS ではまだ動かしていない。

## 役割

今の環境（Amazon Linux 2）の運用中のインスタンスを、**SSM（Session Manager・Run Command）で入れる状態にする**。ほとんどの台は SSM Agent が入って動いていて、IAM ロール（インスタンスプロファイル）がないだけと見込んでいる。そのため、まず未設定の台に SSM 用のインスタンスプロファイルを関連付けて、SSM で実際に入れるかを確かめ、**SSM Agent で直る見込みの台だけ**にバックアップを取ってから、SSH で SSM Agent を入れて有効にする。それ以外の入れない台（止まっている、ロールに権限がない、Online なのにつながらない、など）は、理由を表示して手で直す。作業者の PC で動き、AWS CLI のコマンドと SSH を使う。

80・443 番を国内だけに絞る設定（iptables ＋ ipset）を入れる [port-guard-rollout](../port-guard-rollout/README.md) の**前のフェーズ**として、作業を完全に分けている。port-guard-rollout は、このフェーズの `ssm-check` で「入れる」になった台を、SSM で操作する。

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [手順](./steps.md) | **作業の手順の正本**。フェーズの分け方、流れ、各コマンドの使い方、バックアップの確認、元に戻す方法、手元での試し方 |

## 流れ

流れの図は [手順の「流れ」](./steps.md#流れ)（Mermaid）にある。SVG 版: [SSM の有効化の流れ](images/flow-ssm-setup.svg)、[IAM ロールとインスタンスプロファイルの関係](images/iam-instance-profile.svg)。

コマンドは `ssm-role`（IAM ロールが未設定の台に SSM 用のインスタンスプロファイルを関連付ける）→ `ssm-check --ok-out ok.txt --ng-out ng.txt`（ポリシー・`Online`・SSM で実際に入れるかを確かめ、「入れる」「SSM Agent で直す」「手で直す」に分けて一覧を書き出す）→ SSM Agent で直す台だけ `backup` → `backup-check`（補助）→ `ssm-agent`（SSM Agent がない・止まっている台）→ `ssm-check --ok-out ok2.txt`（もう一度）の順に使う。`ok.txt` と `ok2.txt` の台がフェーズ 2 の対象になる。

```bash
cd ssm-setup
python3 -m ssm_setup --help
python3 -m ssm_setup <コマンド> --help
```

## 実装の方針

port-guard-rollout と同じ方針にしている。

| 項目 | 内容 |
|---|---|
| 言語 | **Python**（標準のライブラリだけを使う）。AMI 公開パイプラインの決定事項 D10（作業者の PC で動く道具は Go）は、この暫定対応の道具には当てはめない |
| AWS の操作 | **作業者の PC に入っている AWS CLI のコマンドを呼ぶ**（AWS SDK は使わない） |
| インスタンスでの実行 | SSH（`ssm-agent` だけ）。`ssm-check` の接続の確認は Session Manager か Run Command |
| port-guard-rollout との共通の部品 | `awscli.py`・`targets.py`・`console.py`・`ssh.py`・`runcommand.py`・`backups.py`・`backup.py`・`backup_check.py` は、port-guard-rollout の同じ名前のファイルの写し（フォルダをまたいで読み込まないため）。違いは、バックアップのタグ `Purpose`（`ssm-setup-backup`）と AMI の名前（`before-ssm-setup`）、`awscli.py` の `run_text`（`ssm-check` の Session Manager で使う）。片方を直したら、もう片方も要るかを見る |

## テスト

AWS・SSH・SSM には接続せず、偽物で確かめる。

```bash
cd ssm-setup
python3 -m unittest discover -s tests
```

## フォルダの中身

| フォルダ | 内容 |
|---|---|
| `ssm_setup/` | 道具の本体（Python）。`ssm_role.py`（IAM ロールの関連付け）、`ssm_agent.py`（SSM Agent の導入）、`ssm_check.py`（SSM で入れるかの確認）、`__main__.py`（コマンドの入り口）と、上の共通の部品 |
| `ssm_setup/remote/` | インスタンスに送るもの。`agent-check.sh`・`agent-install.sh`（SSM Agent の確認と導入） |
| `images/` | 流れの図 `flow-ssm-setup.svg`（作るスクリプトは `make_flow_svg.py`）、IAM ロールとインスタンスプロファイルの関係の図 `iam-instance-profile.svg`（`make_iam_svg.py`） |
| `tests/` | テスト（標準の `unittest`） |

手元の再現の環境（今の構成に近いインスタンスの Docker の定義）は [port-guard-rollout の `al2-instance/`](../port-guard-rollout/al2-instance/README.md) を使う。

## 関連ドキュメント

- [port-guard-rollout（フェーズ 2）](../port-guard-rollout/README.md)
- [検討の経緯: 設計（note）](../notes/ec2-operations/access-restriction-rollout-script-design.md)（「SSM の準備」の検討の記録）
- [SSM Session Manager の運用（note）](../notes/ec2-operations/ssm-session-manager-operations.md)
