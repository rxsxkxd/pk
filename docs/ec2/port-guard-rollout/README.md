# port-guard-rollout — 国内だけに絞る設定（iptables ＋ ipset）を複数台に入れる道具

> 状態: **作りかけ**。今あるのは、**バックアップ（AMI の作成）**、**SSM Agent のインストールと有効化**、**ipset の導入と設定（遮断はまだ効かせない。SSH と SSM の Run Command のどちらでも。dry 実行あり）** のコマンドと、試す相手になる今の構成に近いインスタンスの Docker の定義（`al2-instance/`）。

## 役割

今の環境（Amazon Linux 2・Apache・Passenger・Rails 4.2）の運用中のインスタンスに、特定のポートを国内（日本）だけに絞る設定（iptables ＋ ipset）を、**複数台まとめて**入れる。作業者の PC で動き、AWS の API と SSM の Run Command（SSM の準備の段階だけ SSH）で各インスタンスを操作する。

AL2023 での作り直し（[今の構成を AL2023 で作り直す検討](../initial-image-build/existing-system-rebuild-on-al2023.md)）とは別の、**暫定対応**のための道具である。

## 流れ（チェックポイント）

| 段階 | 内容 |
|---|---|
| チェックポイント 1 | バックアップまで（インスタンスの外の設定の記録、AMI の作成） |
| SSM の準備 | 全台の SSM Agent と権限の確認 → 一覧の表示と確認 → インストール・有効化・権限の付与 → 動作の確認 |
| チェックポイント 2 | 制限の設定の前まで（既存のファイアウォールの確認、ipset の導入、ファイルの配置、日本の IP の範囲の取得、集合の確認） |
| チェックポイント 3 | 制限の有効化と確認（自動で元に戻る予約を入れてから有効化し、確認に合格したものだけ確定） |
| （任意）チェックポイント 4 | 再起動しても戻るかの確認 |

## 実装の方針

| 項目 | 内容 |
|---|---|
| 言語 | **Python**（標準のライブラリだけを使う案）。AMI 公開パイプラインの決定事項 D10（作業者の PC で動く道具は Go）は、この暫定対応の道具には当てはめない |
| AWS の操作 | **作業者の PC に入っている AWS CLI のコマンドを呼ぶ**（AWS SDK は使わない）。認証情報・プロファイル・リージョンは AWS CLI の設定をそのまま使う |
| インスタンスでの実行 | SSH（作業者の PC の `ssh` を呼ぶ）か、SSM の Run Command（AWS CLI の `aws ssm send-command`）。SSM Agent のインストールは SSH だけ |
| 前提 | 作業者の PC に Python 3、AWS CLI（v2）、`ssh`、`nc` が入っていること |
| サーバーに入れる中身 | 設定・スクリプト・systemd のユニット・cron の雛形はシェルのファイルとして道具と一緒に置き、Run Command や SSH で送る処理の中に埋め込む |
| 進め方 | 骨組み（コマンドの形、状態のファイル、全台の確認）から作る |

## 使い方（今あるもの）

### バックアップ（AMI の作成）

インスタンスの ID を標準入力から 1 行に 1 つ渡す。バックアップできるものとできないもの（理由つき）を分けて表示し、試行するかを確かめてから、**1 台ずつ順に** AMI を作る（`create-image --no-reboot`。再起動しない。完了は待たない）。

```bash
cd port-guard-rollout

# 確かめて表示するだけ（AMI は作らない）
python3 -m port_guard_rollout backup --check-only < instance-ids.txt

# 確かめた後に「試行しますか？ [y/N]」と聞き、y なら作る
python3 -m port_guard_rollout backup --profile <プロファイル> --region ap-northeast-1 < instance-ids.txt
```

`instance-ids.txt` の例（空の行と `#` から後は無視する。重複は 1 つにまとめる）:

```
i-0123456789abcdef0   # 物件 A
i-0fedcba9876543210
```

| 項目 | 内容 |
|---|---|
| 確かめること | インスタンスがあるか、状態が `running` か `stopped` か、ルートボリュームが EBS か、AMI を作る権限があるか（`create-image --dry-run` で、実際には作らずに確かめる） |
| 確認の答え | 標準入力はインスタンスの ID の一覧に使うので、端末（`/dev/tty`）から読む。端末がない環境（パイプラインなど）では `--yes` を付けないと止まる |
| AMI の名前 | `<Name タグ>-<インスタンスの ID>-before-port-guard-<実行の ID>`。使えない文字（日本語や空白など）は `-` に置き換える。実行の ID は実行した日時（`YYYYmmdd-HHMMSS`） |
| AMI とスナップショットのタグ | `Name`、`Purpose=port-guard-rollout-backup`、`SourceInstanceId`、`SourceInstanceName`、`BackupRunId` |
| 終了コード | 0: すべて開始できた（または中止した・確かめただけ）、1: 失敗した、または対象外のインスタンスがあった、2: 入力・確認・AWS CLI の問題 |
| 前提 | Python 3（標準のライブラリだけを使う）、AWS CLI（v2）。認証情報・プロファイル・リージョンは AWS CLI の設定と、`--profile`・`--region` |
| 権限 | `ec2:DescribeInstances`、`ec2:CreateImage`、`ec2:CreateTags`（AMI とスナップショットへのタグ） |

設計のチェックポイント 1 のうち、今あるのは AMI の作成だけ（インスタンスの外の設定の記録と、SSM での `sync` はまだない）。

### SSM Agent のインストールと有効化

設計の「SSM の準備」に当たる（インスタンスプロファイルと IAM の権限の付与は含まない。C3 は試すのを保留）。SSM Agent がまだないインスタンスが相手なので、**SSH** で入る。入力と確認の形は、ほかのコマンドと同じ。

```bash
python3 -m port_guard_rollout ssm-agent --check-only < instance-ids.txt   # 確かめて表示するだけ
python3 -m port_guard_rollout ssm-agent --ssh-key ~/.ssh/<鍵> < instance-ids.txt
```

| 段階 | 内容 |
|---|---|
| 確認（読み取りだけ） | SSH で SSM Agent の有無・起動時の有効化・動作、インスタンスのメタデータからインスタンスプロファイルの有無とリージョン、AWS の窓口（`ssm.<リージョン>.amazonaws.com`）に届くかを見る。AWS CLI で登録の状態（`Online` など）も見る |
| 行うこと | 入っていない → **インストール**、入っているが止まっている → **有効化と起動**、動いているのに登録されていない → **起動し直し**、`Online` → 何もしない |
| 対応できない | SSH で入れない、`sudo` を使えない、Amazon Linux 2 ではない、動いているがインスタンスプロファイルがない・AWS の窓口に届かない |
| 導入 | `yum install amazon-ssm-agent`（入っていなければ）→ `systemctl enable` → `systemctl restart`（認証情報を取り直させる）→ `ssm-cli get-diagnostics`（あれば） |
| 登録の確認 | すべての台を処理した後、`--wait-online`（既定 300 秒）まで、AWS の側で `Online` になるのを待つ。ならなければ、見る場所（インスタンスプロファイル、送信の 443 番、エージェントのログ）を表示する |

インスタンスプロファイルがない台は、入れても `Online` にならない（注意として表示する）。手元の `al2-instance` で試すときは `--no-aws`（AWS を見ない）を付ける（2026-10-29 にインストールまで確認。systemd がないので起動は飛ばす）。

### ipset の導入と設定（遮断はまだ効かせない）

設計のチェックポイント 2（制限の設定の前まで）に当たる。バックアップと同じく、対象を標準入力から 1 行に 1 台で渡し、入れられるものとできないもの（理由つき）を分けて表示し、試行するかを確かめてから、**1 台ずつ順に**行う。

実行の手段は `--via` で選ぶ。

| `--via` | 内容 |
|---|---|
| `ssh`（既定） | 作業者の PC の `ssh` を呼び、インスタンスの中で `sudo -n bash -s` で実行する。今のインスタンスは SSM Agent がない見込みなので、こちらが基本 |
| `ssm` | AWS CLI の `aws ssm send-command`（`AWS-RunShellScript`）で送り、`get-command-invocation` で結果を待つ（root で実行される）。SSM に登録されて `Online` のインスタンスだけが対象で、2 列目の SSH の接続先は使わない。処理は base64 にして 1 行のコマンドとして送る |

```bash
cd port-guard-rollout

# 確かめて表示するだけ
python3 -m port_guard_rollout install --ports 8443 --check-only < instance-ids.txt

# dry 実行: 確かめて、行う予定の処理と、前回の設定から変わること（ポート、許可する IP の増減）を表示する。変更はしない
python3 -m port_guard_rollout install --ports 8443 --allow-file allow.txt --dry-run --script-out /tmp/script.sh < instance-ids.txt

# SSM の Run Command で行う
python3 -m port_guard_rollout install --via ssm --ports 8443 --allow-file allow.txt < instance-ids.txt

# 導入と設定（確かめた後に「試行しますか？ [y/N]」と聞く）
python3 -m port_guard_rollout install --ports 8443 --allow-file allow.txt \
  --ssh-user centos --ssh-key ~/.ssh/<鍵> \
  --check-in-jp <日本の回線の IP> --check-outside <海外の IP> < instance-ids.txt
```

入力の各行は `<インスタンスの ID> [<SSH の接続先>]`。接続先（`host`、`host:port`、`user@host:port`）を省略すると、AWS CLI でインスタンスの IP を引く（既定はパブリック IP。`--address private` でプライベート IP）。

```
i-0123456789abcdef0                # 接続先は AWS CLI で引く
i-0fedcba9876543210  10.0.1.23     # 接続先を直接書く
```

| 段階 | 内容 |
|---|---|
| 確認（読み取りだけ） | SSH で入れるか、`sudo` をパスワードなしで使えるか、Amazon Linux 2 か。firewalld が動いている・起動時に有効、iptables のサービスが起動時に有効、既存の iptables のルールがある、既存の ipset の集合がある、port-guard の遮断がすでに有効、のどれかなら**入れない**（理由を表示する）。port-guard のファイルがすでにある（上書きする）、systemd が動いていない（ユニットの登録を飛ばす）は、注意として表示して進める |
| 導入と設定 | `yum install ipset python3` → 設定（`/etc/port-guard/port-guard.conf`、`allow.txt`）・2 つのスクリプト・systemd のユニットを置く（`daemon-reload` まで。enable しない）→ 日本の IP の範囲を取って集合を作る（`port-guard-update-jp`） |
| 導入の後の確認 | 集合の件数、遮断のルール（INPUT からの参照）がないこと、`port-guard` と `ipset` のユニットが起動時に有効になっていないこと、`--check-in-jp` の IP が日本の集合に入っていること、`--check-outside` の IP がどちらの集合にも入っていないこと |

| オプション | 内容 |
|---|---|
| `--ports` | 絞るポート（必須。複数ならカンマ区切り） |
| `--allow-file` | 許可する IP の一覧（1 行 1 件、CIDR 可、`#` から後はコメント）。省略すると空 |
| `--jp-min-entries` | 日本の IP の範囲の最低件数（既定 1000。これより少なければ取得の失敗とみなす） |
| `--ssh-user`・`--ssh-key`・`--ssh-option` | SSH のユーザー（既定 `centos`）、秘密鍵、`ssh -o` に渡す値（何度でも指定できる）。踏み台などは作業者の SSH の設定に書いておけばそのまま使える。初めての接続先のホストの鍵は自動で登録する（`StrictHostKeyChecking=accept-new`） |
| `--check-in-jp`・`--check-outside` | 確認に使う IP（何度でも指定できる） |
| `--via` | 実行の手段（`ssh` か `ssm`。上の表） |
| `--dry-run`・`--script-out` | 変更せずに、行う予定の処理と前回の設定から変わることを表示する。`--script-out` で、インスタンスに送る処理をファイルに書き出す（中身を確かめるため） |

**注意: 定期の更新（cron）はまだ置かない（保留）**。`install` は、日本の IP の範囲を**実行した時点で 1 回だけ**取り、許可する IP も**実行した時点の `--allow-file` の中身**で集合を作る。その後は自動では更新されない。このあと遮断を有効にすると（チェックポイント 3。コマンドはまだない）、**`install` を実行した時点で置かれた一覧（集合の中身）が、そのまま遮断のルールに使われる**。有効にする前に一覧を新しくしたいときは、`install` をもう一度実行する（集合の中身だけが入れ替わる）。

手元の `al2-instance` で試すとき（2026-10-28 に確認。約 9 秒、日本の範囲 4,738 件）:

```bash
cd port-guard-rollout
printf 'i-00000001 localhost:2222\n' | python3 -m port_guard_rollout install --ports 8443 --yes \
  --ssh-key al2-instance/ssh/id_ed25519 \
  --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no \
  --check-in-jp 133.11.0.1 --check-outside 8.8.8.8
```

### テスト

AWS と SSH には接続せず、偽物で確かめる。

```bash
cd port-guard-rollout
python3 -m unittest discover -s tests
```

## フォルダの中身

| フォルダ | 内容 |
|---|---|
| `port_guard_rollout/` | 道具の本体（Python）。`awscli.py`（AWS CLI を呼ぶ）、`ssh.py`（SSH で root として処理を実行する）、`runcommand.py`（SSM の Run Command で root として処理を実行する）、`ssm_agent.py`（SSM Agent のインストール）、`targets.py`（標準入力の読み込み）、`console.py`（確認）、`backup.py`（バックアップ）、`install.py`（ipset の導入と設定）、`__main__.py`（コマンドの入り口） |
| `port_guard_rollout/remote/` | インスタンスに送るもの。`check.sh`（確認）、`install.sh`（導入と設定）、`ssm-check.sh`・`ssm-install.sh`（SSM Agent の確認とインストール）、サーバーに置く `port-guard-apply`・`port-guard-update-jp`・`port-guard.service`（[暫定対応のドキュメント](../notes/ec2-operations/access-restriction-os-firewall.md) のものと同じ） |
| `tests/` | テスト（標準の `unittest`） |
| [`al2-instance/`](./al2-instance/README.md) | 今の構成（AL2・Apache 2.4.56・Passenger 6.0.18・Ruby 2.7.7・Rails 4.2）に近いインスタンスを手元で再現する Docker の定義。道具を試す相手にする |

## 関連ドキュメント

- [設計: 国内だけに絞る設定（iptables ＋ ipset）を複数台に入れるスクリプト](../notes/ec2-operations/access-restriction-rollout-script-design.md)（チェックポイント、状態の管理、権限、決めること C1〜C9）
- [作業計画: OS（iptables ＋ ipset）で特定のポートを国内だけに絞る](../notes/ec2-operations/access-restriction-os-firewall-work-plan.md)（1 台を手で行う場合の計画）
- [暫定対応: OS（iptables ＋ ipset、または firewalld）で特定のポートを国内と特定の IP に絞る](../notes/ec2-operations/access-restriction-os-firewall.md)（サーバーに入れる設定・スクリプト・ユニットの中身）
