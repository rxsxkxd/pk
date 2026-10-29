# port-guard-rollout — 国内だけに絞る設定（iptables ＋ ipset）を複数台に入れる道具

> 状態: 確定した手順（バックアップ → SSM Agent の導入 → ipset の導入と設定 → 遮断の有効化）のコマンドがそろっている。手元の再現の環境（`al2-instance/`）では最後まで確かめた。実際の AWS ではまだ動かしていない。

## 役割

今の環境（Amazon Linux 2・Apache・Passenger・Rails 4.2）の運用中のインスタンスに、**80・443 番を国内（日本）と許可した IP だけに絞る設定**（OS の iptables ＋ ipset）を、**複数台まとめて**入れる。SSH の 22 番は既定では絞らない（外部からの SSH はセキュリティグループで弾く前提。必要なら `install --include-ssh` で対象にできる）。作業者の PC で動き、AWS CLI のコマンドと、SSH または SSM の Run Command で各インスタンスを操作する。

AL2023 での作り直し（[今の構成を AL2023 で作り直す検討](../initial-image-build/existing-system-rebuild-on-al2023.md)）とは別の、**暫定対応**のための道具である。

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [手順](./steps.md) | **作業の手順の正本**。確定した内容、流れ、各コマンドの使い方、バックアップの確認、元に戻す方法、手元での試し方 |
| [構成の提案: 海外からの確認の拠点](./outside-probe.md) | 遮断の後に「海外からつながらない」ことを確かめる接続元（AWS の別のリージョンの AL2023 のインスタンス）の構成、確認の処理 `port-guard-probe` の使い方と、作業者が手で確かめる流れ |
| [iptables ＋ ipset の仕組みと確認](./iptables-ipset.md) | インスタンスに入れる仕組みの詳細。**アクセス制限の構成の図**（[SVG](images/access-architecture.svg)。VPC・セキュリティグループ・OS・httpd・Rails・SSM）、事前の確認、効き始める時点、手で確かめる・外す方法、気を付けること（Let's Encrypt の更新への影響など） |

## 流れ

流れの図は [手順の「流れ」](./steps.md#流れ)（Mermaid）にある。SVG 版: [全体の流れ](images/flow-overall.svg)、[enable のインスタンスごとの流れ](images/flow-enable.svg)。

コマンドは `backup` → `backup-check`（補助）→ `ssm-role`（IAM ロールが未設定の台に SSM 用のインスタンスプロファイルを関連付ける）→ `ssm-agent`（SSM Agent がない・止まっている台）→ `install` → `enable` の順に使う。

```bash
cd port-guard-rollout
python3 -m port_guard_rollout --help
python3 -m port_guard_rollout <コマンド> --help
```

## 実装の方針

| 項目 | 内容 |
|---|---|
| 言語 | **Python**（標準のライブラリだけを使う）。AMI 公開パイプラインの決定事項 D10（作業者の PC で動く道具は Go）は、この暫定対応の道具には当てはめない |
| AWS の操作 | **作業者の PC に入っている AWS CLI のコマンドを呼ぶ**（AWS SDK は使わない）。認証情報・プロファイル・リージョンは AWS CLI の設定をそのまま使う |
| インスタンスでの実行 | SSH（作業者の PC の `ssh` を呼ぶ）か、SSM の Run Command（AWS CLI の `aws ssm send-command`）。SSM Agent の導入は SSH だけ |
| サーバーに入れる中身 | 設定・スクリプト・systemd のユニットはシェルのファイル（`port_guard_rollout/remote/`）として道具と一緒に置き、SSH や Run Command で送る処理の中に埋め込む |

## テスト

AWS・SSH・SSM には接続せず、偽物で確かめる。

```bash
cd port-guard-rollout
python3 -m unittest discover -s tests
```

## フォルダの中身

| フォルダ | 内容 |
|---|---|
| `port_guard_rollout/` | 道具の本体（Python）。`awscli.py`（AWS CLI を呼ぶ）、`ssh.py`（SSH で root として処理を実行する）、`runcommand.py`（SSM の Run Command で root として処理を実行する）、`ssm_agent.py`（SSM Agent の導入）、`targets.py`（標準入力の読み込み）、`console.py`（確認）、`backups.py`（操作の前のバックアップの確認）、`backup.py`（バックアップ）、`backup_check.py`（バックアップがあるかを確かめるだけ）、`install.py`（ipset の導入と設定）、`enable.py`（遮断の有効化）、`__main__.py`（コマンドの入り口） |
| `port_guard_rollout/remote/` | インスタンスに送るもの。`check.sh`（確認）、`install.sh`（導入と設定）、`ssm-check.sh`・`ssm-install.sh`（SSM Agent の確認と導入）、`enable-check.sh`・`enable-apply.sh`・`enable-confirm.sh`・`enable-revert.sh`（遮断の有効化の確認・有効化・確定・元に戻す）、サーバーに置く `port-guard-apply`・`port-guard-update-jp`・`port-guard.service` |
| `images/` | フローの図（SVG）と、それを作り直すスクリプト `make_svg.py`（`python3 images/make_svg.py images`）。アクセス制限の構成の図 `access-architecture.svg`（作るスクリプトは `make_access_svg.py`）。IAM ロールとインスタンスプロファイルの関係の図 `iam-instance-profile.svg`（`make_iam_svg.py`） |
| `tests/` | テスト（標準の `unittest`） |
| [`al2-instance/`](./al2-instance/README.md) | 今の構成（AL2・Apache 2.4.56・Passenger 6.0.18・Ruby 2.7.7・Rails 4.2）に近いインスタンスを手元で再現する Docker の定義。道具を試す相手にする。開発用のアカウントの、本番とは別の VPC に EC2 として作るための [EC2 Image Builder の定義](./al2-instance/image-builder/README.md)（下書き・未検証）も置いている |
| [`outside-probe/`](./outside-probe/docker/README.md) | 海外からの確認の拠点（チェック用のクライアント。AL2023）の定義。`port-guard-probe`（確認の処理）、[Docker の定義](./outside-probe/docker/README.md)（手元で試す用）、[EC2 Image Builder の定義](./outside-probe/image-builder/README.md)（別のリージョンで使う AMI） |

## 関連ドキュメント

- [検討の経緯: 設計（note）](../notes/ec2-operations/access-restriction-rollout-script-design.md)（チェックポイント、決めること C1〜C9 などの検討の記録）
- [暫定対応: OS（iptables ＋ ipset、または firewalld）で絞る（note）](../notes/ec2-operations/access-restriction-os-firewall.md)（方式の比較。iptables ＋ ipset の詳細は [iptables-ipset.md](./iptables-ipset.md) に移した）
