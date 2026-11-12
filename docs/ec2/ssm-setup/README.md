# ssm-setup — SSM を使えるようにする道具（フェーズ 1）

> 状態: 道具（AWS の操作の Ruby、接続の確認とインスタンスの中の操作の sh、踏み台サーバーのロールの CloudFormation のテンプレート）がそろっている。確かめたのは構文と書き方（rubocop・`bash -n`・`cfn-lint`）だけで、AWS でも稼働サーバーでも、まだ動かしていない。

## 役割

今の環境（Amazon Linux 2）の運用中の稼働サーバーを、**SSM（Session Manager・Run Command）で入れる状態にする**。ほとんどの台は SSM Agent が入って動いていて、IAM ロール（インスタンスプロファイル）がないだけと見込んでいる。そのため、まず未設定の台に SSM 用のインスタンスプロファイルを関連付けて、SSM で実際に入れるかを確かめ、**SSM Agent で直る見込みの台だけ**にバックアップを取ってから、SSM Agent を入れて有効にする。それ以外の入れない台は、理由を表示して手で直す。

80・443 番を国内だけに絞る設定を入れる [port-guard-rollout](../port-guard-rollout/README.md) の**前のフェーズ**として、作業を完全に分けている。port-guard-rollout は、このフェーズの接続の確認で「入れる」になった台を、SSM で操作する。

手順の正本は [steps.md](./steps.md)（用語、流れの図、各道具の使い方、権限、元に戻す方法）。

## 構成: 操作を 3 つに分ける

| | AWS の操作 | 接続の確認 | インスタンスの中の操作 |
|---|---|---|---|
| フォルダ | `rb/` | `connect/` | `instance/` |
| 書くもの | Ruby（標準のライブラリだけ。gem は使わない） | sh（bash） | sh（bash） |
| どこで動くか | 作業者の PC | 作業者の PC と踏み台サーバー（同じスクリプトを両方で流す） | 稼働サーバー |
| AWS への届き方 | AWS CLI のコマンドを呼ぶ | AWS CLI のコマンドを呼ぶ（`ssm start-session`・`ssm send-command`） | 呼ばない |
| 稼働サーバーへの届け方 | （届けない） | SSM | **ssm-setup の範囲外**（別の枠組みで届けて流す） |

- 別々の区分の操作を 1 つのコマンドに入れない（前の Python 版の `ssm-agent` は、AWS の操作と SSH でのインスタンスの中の操作を 1 つにつないでいて、いちばん大きなコマンドになっていた）
- 接続の確認は、作業者の PC からだけでなく踏み台サーバーからも SSM で入れるかを見る。踏み台サーバーには Ruby がないので sh にし、踏み台サーバーには IAM ロール（`cloudformation/bastion-role.yml`）を付ける
- 踏み台サーバーから稼働サーバーへの SSH での操作（SSM Agent の導入のスクリプトを届けること、接続先の決め方）は範囲外。SSH での操作を SSM Agent による操作に一本化するかは、ssm-setup の外で検討する

## 道具

| 区分 | ファイル | すること | 変えるもの |
|---|---|---|---|
| AWS の操作 | `rb/ssm_role.rb` | IAM ロールが未設定の台に、SSM 用のインスタンスプロファイルを関連付ける | インスタンスプロファイルの関連付け |
| | `rb/ssm_check.rb` | 権限と AWS の上の状態で、SSM 有効・SSM Agent で直す・手で直す に分ける | なし |
| | `rb/backup.rb` | SSM Agent で直す台の AMI を作る（再起動しない） | AMI |
| | `rb/backup_check.rb` | バックアップがそろったかを確かめ、そろった台の一覧を書き出す | なし |
| 接続の確認 | `connect/ssm-connect-check.sh` | Session Manager と Run Command で `echo` を流し、実際に入れるかを見る | なし |
| インスタンスの中の操作 | `instance/agent-check.sh` | SSM Agent の状態を見て、次に行うことを出す | なし |
| | `instance/agent-install.sh` | SSM Agent を入れる・有効にする・起動し直す | パッケージ、サービス |
| 踏み台サーバー | `cloudformation/bastion-role.yml` | 踏み台サーバーの IAM ロールとインスタンスプロファイル（接続の確認に使う） | IAM |

```bash
cd ssm-setup
ruby rb/ssm_role.rb --help
ruby rb/ssm_check.rb --help
ruby rb/backup.rb --help
ruby rb/backup_check.rb --help
bash connect/ssm-connect-check.sh --help
```

## 実装の方針

| 項目 | 内容 |
|---|---|
| 言語 | AWS の操作は **Ruby**（2.6 以上。標準のライブラリだけ）。接続の確認とインスタンスの中の操作は **sh**（bash。macOS の bash 3.2 でも動く書き方。`jq` などは使わない）。AMI 公開パイプラインの決定事項 D10（作業者の PC で動く道具は Go）は、この暫定対応の道具には当てはめない |
| AWS の操作 | **作業者の PC に入っている AWS CLI のコマンドを呼ぶ**（AWS SDK は使わない）。認証情報・リージョンは AWS CLI の設定（`AWS_PROFILE`・`AWS_REGION` など） |
| 共通の流れ | 設定を変える `rb/ssm_role.rb`・`rb/backup.rb` は、確かめる（Plan を作る）と行う（ブロック）だけを書き、表示・`--check-only`・`[y/N]` の確認・`--yes`・1 台ごとの失敗・終了コードは `rb/flow.rb` に任せる。確かめるだけの道具は使わない |
| バックアップ | 本体と別の道具（`rb/backup.rb`・`rb/backup_check.rb`）。タグ `Purpose=ssm-setup-backup` で、ほかの作業のバックアップと分ける |
| 書き方の確認 | Ruby は rubocop の既定（`rb/.rubocop.yml` で確かめる版を Ruby 2.6 にしているだけ）。gem を置かないので、rubocop はほかの道具の Gemfile を借りて流す: `cd ssm-setup/rb && BUNDLE_GEMFILE=../../al2-update/rb/Gemfile bundle exec rubocop` |
| テスト | なし（AWS に接続しない偽物での確認は保留） |

## フォルダの中身

| フォルダ | 内容 |
|---|---|
| `rb/` | AWS の操作。コマンドの `ssm_role.rb`・`ssm_check.rb`・`backup.rb`・`backup_check.rb` と、部品の `lib.rb`（AWS CLI の呼び出し、一覧の読み込み、端末での確認）・`ssm_setup.rb`（このフェーズの共通の部品）・`flow.rb`（共通の流れ）・`host_state.rb`（`ssm_check.rb` の 1 台の状態）・`backups.rb`（バックアップの決まり） |
| `connect/` | 接続の確認。`ssm-connect-check.sh` |
| `instance/` | インスタンスの中の操作。`agent-check.sh`・`agent-install.sh` |
| `cloudformation/` | 踏み台サーバーの IAM ロール。`bastion-role.yml` |
| `images/` | 図の SVG と、それを作るスクリプト（`make_flow_svg.py`・`make_iam_svg.py`）。流れの図の正本は [手順](./steps.md#流れ) の Mermaid で、変えたら SVG も作り直す |

## 関連ドキュメント

- [port-guard-rollout（フェーズ 2）](../port-guard-rollout/README.md)
- [検討の経緯: 設計（note）](../notes/ec2-operations/access-restriction-rollout-script-design.md)（「SSM の準備」の検討の記録）
- [SSM Session Manager の運用（note）](../notes/ec2-operations/ssm-session-manager-operations.md)
- [SSM の操作を特定の中継サーバーからだけに絞る IAM の設定（note。検討と設定の下書き）](../notes/ec2-operations/ssm-relay-server-access-control.md)
