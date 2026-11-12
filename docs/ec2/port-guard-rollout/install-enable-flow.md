# install・enable の処理の流れ（sh 版・Ruby 版）

`install` と `enable` を、機能を絞って sh と Ruby で書き直した版の処理の流れ。作業の手順（どの順にコマンドを使うか）は [手順](./steps.md) が正本で、ここは 1 つのコマンドの中で何をしているかを書く。ssm-setup にも同じ作りの sh 版・Ruby 版があったが、ssm-setup の側は Python 版だけに絞った。

> 状態: 書いただけ（構文と rubocop の確認だけ済み）。実際の AWS ではまだ動かしていない。Python 版（`py/`）は残してあり、どれを使うかは決めていない。

## ファイル

| ファイル | 内容 |
|---|---|
| `sh/install.sh`・`rb/install.rb` | ipset の導入と設定（遮断はまだ効かせない） |
| `sh/enable.sh`・`rb/enable.rb` | 遮断の有効化（台ごとに y/n/q で確かめ、自動で元に戻る予約を入れてから有効にし、確かめて確定か戻す） |
| `rb/port_guard.rb` | Ruby 版のこのフェーズだけの部品。バックアップの確認、送った結果（`PG <キー>=<値>`・`PG blocked=<理由>`・`PGSTEP`）の読み取り、作業者の PC からの応答の確認 |
| `sh/lib.sh`・`rb/lib.rb` | 共通の部品（ssm-setup の `sh/lib.sh`・`rb/lib.rb` の写し） |
| `rb/Gemfile`・`rb/.rubocop.yml` | 書き方の確認の rubocop だけを入れる（道具は標準のライブラリだけで動く） |
| `remote/` | インスタンスに送るもの（Python 版・sh 版・Ruby 版で共用）。sh 版・Ruby 版は、入れてよいか・有効にできるかを `install-preflight.sh`・`enable-preflight.sh` でインスタンスの側で確かめる |

```bash
cd port-guard-rollout
ruby rb/install.rb --backup-label 2026-10 [--allow-file allow.txt] [--include-ssh] [--check-only] [--yes] < ok.txt
ruby rb/enable.rb --backup-label 2026-10 [--revert-minutes 10] [--yes] < ok.txt
sh/install.sh --backup-label 2026-10 [--allow-file allow.txt] [--include-ssh] [--check-only] [--yes] < ok.txt
sh/enable.sh --backup-label 2026-10 [--revert-minutes 10] [--yes] < ok.txt

# Ruby 版の書き方の確認（rubocop を入れるのは初回だけ）
cd rb && bundle install && bundle exec rubocop
```

| 前提 | 内容 |
|---|---|
| 作業者の PC | AWS CLI（v2）。sh 版は bash（macOS の bash 3.2 でも動く書き方）と `curl`。Ruby 版は Ruby 2.6 以上、標準のライブラリだけ |
| 送り方 | SSM の Run Command だけ（SSH の経路はない。手元の再現の環境では試せない） |
| 認証情報・リージョン | AWS CLI の設定をそのまま使う（`AWS_PROFILE`・`AWS_REGION` など） |

Ruby 版は、どちらも 1 つのクラスで、流れの大枠を公開のメソッドとして上に並べ、ヘルパは `private` の下に分けている。

## install（rb/install.rb の `PortGuardInstall`）

流れは「バックアップの確認 → 入れてよいかの確認 → 導入」。

```mermaid
%%{init: {"themeVariables": {"fontSize": "16px"}, "flowchart": {"nodeSpacing": 30, "rankSpacing": 40}}}%%
flowchart TD
    Read["標準入力からインスタンスの ID を読む"] --> Backup["バックアップの確認（PortGuard.check_backups）<br>BackupLabel が合い、作成が終わっていて、12 時間以内の AMI があるか"]
    Backup -->|ない| NoBackup["バックアップなし（行わない）"]
    Backup -->|ある| Pre["入れてよいかの確認（check_preflight）<br>インスタンスで install-preflight.sh（読み取りだけ）"]
    Pre -->|"PG blocked=…"| Blocked["入れられない（理由を表示）"]
    Pre -->|入れられる| Mode{"--check-only？"}
    Mode -->|はい| End["終わる"]
    Mode -->|いいえ| Ask{"[y/N] の確認（--yes なら飛ばす）"}
    Ask -->|y| Install["導入（install_all）<br>1 台ずつ、渡す値（PG_*）＋ install-preflight.sh ＋ install.sh を送る<br>（送る直前にも、インスタンスの側でもう一度確かめる）"]
    Install --> Result["完了・失敗を表示する<br>（バックアップなし・入れられない・失敗があれば 1）"]
```

## enable（rb/enable.rb の `PortGuardEnable`）

流れは「バックアップの確認 → 1 台ずつ、確かめながら有効にする → 結果を表示する」。1 台の中は「予約を入れて有効にする → 確かめる → 確定か戻す」。

```mermaid
%%{init: {"themeVariables": {"fontSize": "16px"}, "flowchart": {"nodeSpacing": 30, "rankSpacing": 40}}}%%
flowchart TD
    Read["標準入力からインスタンスの ID を読む"] --> Backup["バックアップの確認（PortGuard.check_backups）"]
    Backup --> Each{"1 台ずつ [y/n/q]<br>（--yes なら y）"}
    Each -->|n| Skip["飛ばした"]
    Each -->|q| Stop["残りを止めた"]
    Each -->|y| Apply["有効化（apply_with_auto_revert）<br>enable-preflight.sh ＋ enable-apply.sh を送る<br>（決めた時間の後に自動で元に戻る予約を入れてから有効にする）"]
    Apply -->|有効にできない| Fail["失敗（途中まで進んでいたら、すぐに戻す）"]
    Apply -->|有効にした| Verify["確かめる（verify）<br>SSM で引き続き入れるか<br>作業者の PC から対象のポートが応答するか（22: SSH の応答、80: HTTP、443: TLS）"]
    Verify -->|合格| Confirm["確定（enable-confirm.sh で予約を取り消す）"]
    Verify -->|不合格| Revert["戻した（enable-revert.sh。SSM で入れなければ予約で戻る）"]
    Skip & Fail & Confirm & Revert --> Each
    Stop --> Result["結果を表示する<br>（すべて確定なら 0、ほかがあれば 1）"]
    Each -->|最後の台の後| Result
```

## Python 版との違い

| 項目 | Python 版（`py/`） | sh 版・Ruby 版 |
|---|---|---|
| 送り方 | SSH か SSM の Run Command（`--via`） | SSM の Run Command だけ |
| 入れてよいか・有効にできるかの確認 | 作業者の PC で、インスタンスから読んだ状態を判定する | インスタンスの側で `*-preflight.sh` が判定し、理由を返す |
| dry 実行、前回の設定からの差分の表示、`--port-map`・`--probe`・`--check-in-jp` など | ある | ない |
| テスト | `py/tests/`（AWS・SSH に接続しない偽物） | まだない（構文と rubocop の確認だけ） |
