# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このディレクトリの性格

今の環境（AL2）への暫定対応の**フェーズ 2 `port-guard-rollout`** の道具とドキュメント。2026-11-16 に `docs/ec2/port-guard-rollout/` から移した（あわせて `docs/ec2/api-access-sources/` を `api-access-sources/` に移した）。フェーズ 1（`ssm-setup`）と、ほかの暫定対応の道具（`sg-ssh-restrict`・`al2-update`）は `docs/ec2/` に残っている。

ドキュメントの追記・修正は日本語で行い、用語はできるだけ省略しない。

取り違えやすい表現は、正確な名前を決めて明示する。「対象のサーバー」「対象」のように文脈で指すものが変わる語をそのまま使わず、役割が分かる名前（例: 「稼働サーバー」「中継サーバー」）を決める。1 つのドキュメントの中では、同じものは同じ名前で、違うものは違う名前で書く。役割の近いものが複数出てくるドキュメントでは、冒頭の「用語」の節で定義する。

- 暫定対応のフェーズ 1（`docs/ec2/ssm-setup/`）とフェーズ 2（このフォルダ）は、**完全に分けている**（別のフォルダ・別の道具・別のバックアップ。AMI のタグ `Purpose` で分ける。フェーズ 2 は `port-guard-rollout-backup`）。標準のライブラリだけ、AWS の操作は AWS CLI のコマンドを呼ぶ。確定した内容以外の事項（cron など）は道具に入れない
- **80・443 番だけ**を国内と許可した IP に絞る設定（iptables ＋ ipset）を複数台まとめて入れる（`python3 -m port_guard_rollout`。`install` → `enable`。その前のバックアップは `python3 -m port_guard_rollout_backup`。フェーズ 1 の `command/connect/ssm-connect-check.sh` で入れる台を、SSM の Run Command（`--via ssm`。SSH も可）で操作する）。SSH の 22 番は既定では絞らない（外部からの SSH はセキュリティグループで弾く前提。`install --include-ssh` で対象にできる準備はある）
- 手順の正本は `steps.md`、仕組みは `iptables-ipset.md`。踏み台サーバーから SSH で入れる手順は `bastion-install-commands.md`（補足は `bastion-install-supplement.md`）
- Python 版は `py/`、機能を絞った sh 版は `sh/`、Ruby 版は `rb/`（sh 版と Ruby 版は SSM の Run Command だけ。Ruby 版の書き方は rubocop の既定で、`cd rb && bundle exec rubocop`）。インスタンスに送るものは 3 つで共用する `remote/`
- Python 版のバックアップは別のパッケージ `port_guard_rollout_backup/`（本体の部品を使い、本体は操作の前の確認だけを使う）。インスタンスを操作するコマンドは、確かめる（`plan`）と行う（`apply`）だけを書き、入力・前提の確認（`Stop`）・表示・確認・1 台ごとの失敗（`Failed`）・終了コードは共通の流れ `flow.py` に任せる（`enable` は 1 台ごとに確かめるので部品だけを使う。バックアップの `check` は使わない）。共通の部品（`awscli.py`・`ssh.py`・`runcommand.py`・`flow.py`・`backup.py` など）は、もとは ssm-setup の Python 版と写し合っていたが、ssm-setup は Ruby と sh に作り直したので、今はこのフォルダだけが持つ
- テストは `cd py && python3 -m unittest discover -s tests`（AWS・SSH には接続しない）
- `notes/` は検討の経緯の記録（2026-11-16 に `docs/ec2/notes/ec2-operations/` から移した作業計画と、複数台に入れるスクリプトの設計）。確定した手順は `steps.md` が正本で、`notes/` の内容を採用済みの設計として扱わない
- 試す相手になる今の構成に近いインスタンスの Docker の定義は `al2-instance/`。port-guard を有効にする前に API の送り元を洗い出す道具の設計は `api-access-sources/design.md`

## AWS について調べるとき

AWS の仕様・挙動・制限をドキュメントに書くときは、**一次情報を AWS 自身の公開の情報で確かめる**。記憶や第三者の記事だけを根拠にしない。

| 種類 | 情報源 | 扱い |
|---|---|---|
| 仕様・挙動・設定の仕方・制限 | `docs.aws.amazon.com`（各サービスのユーザーガイド、API リファレンス、AWS CLI のリファレンス） | **一次情報の基本**。まずここを辿る |
| 料金 | `aws.amazon.com/<サービス>/pricing/` | 一次情報。数値は変わるので、書くなら調べた日を添える |
| 新機能・変更の発表 | `aws.amazon.com/about-aws/whats-new/` | 一次情報（いつから使えるかの確認に） |
| AWS のブログ（`aws.amazon.com/blogs/`）、AWS re:Post（`repost.aws`） | AWS の公開の情報だが、書かれた時点の情報で、古くなっていることがある | 補助。仕様の根拠にするときは `docs.aws.amazon.com` でも確かめる |
| AWS 以外のブログ・記事・回答 | — | 一次情報としない（手がかりとして使い、`docs.aws.amazon.com` で確かめ直す） |

- ドキュメントには、根拠にした AWS のページへのリンクと、確かめた日を書き残す（例: 「AWS のドキュメントと照らし合わせた（2026-11-05）」と「参考」の節）
- 確かめられなかったこと（AWS のドキュメントに書かれていない、実機で試していない）は、そう明記する。推測で断定しない
