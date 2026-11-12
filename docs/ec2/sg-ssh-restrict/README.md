# sg-ssh-restrict — セキュリティグループの 22 番（SSH）を絞る道具

> 状態: 書いただけ（構文と rubocop の確認、規則の振り分けの手での確認だけ済み）。実際の AWS ではまだ動かしていない。A と B のどちらを使うかは、環境を見て決める。

## 役割

22・80・443 番を許可しているセキュリティグループが付いたインスタンスで、**22 番だけを、許可する範囲（`--allow-cidr`）からだけ受けるように絞る**。80・443 番の規則は変えない。やり方を 2 つ用意していて、どちらも、変える前に確かめるだけのモード（`--check-only`）、変えた内容の記録、記録から元に戻す道具（`restore.rb`）を持つ。

80・443 番を国内だけに絞るのは、規則の件数の上限があるので、セキュリティグループではなく [port-guard-rollout](../port-guard-rollout/README.md)（iptables ＋ ipset）で行う。22 番をここで絞れば、port-guard の `--include-ssh` は要らない。

## どちらを使うか

| | A. 規則を直す（`rb/restrict_rule.rb`） | B. 付け替える（`rb/swap_groups.rb`） |
|---|---|---|
| すること | 今のグループの 22 番の規則を、許可する範囲に絞る | 22 番を除いた写し（`<名前>-no-ssh`）と、22 番を絞ったグループ（`<名前>-ssh-limited`）を用意し、インスタンスの古いグループを付け替える |
| 影響の範囲 | **そのグループを付けた全部のインスタンス**に、すぐ効く | 付け替えたインスタンスだけ |
| 入力 | セキュリティグループの ID の一覧 | インスタンスの ID の一覧（と `--old-group`） |
| 向いているとき | そのグループを使う全台で、22 番を同じに絞ってよい。グループがほかのグループの規則の相手になっている | 一部の台だけ絞りたい。1 台ずつ進めたい |
| 止まる・残るもの | 22 番を含むポートの範囲の規則（すべての通信など）は「手で直す」として残す | 古いグループがほかのグループの規則の相手になっている、自分自身を相手にしている、22 番を含むポートの範囲の規則がある、のどれかなら止める（A を使う） |

決めるために見るとよいこと（どちらの道具も `--check-only` で表示する）:

- そのグループを付けているインスタンスの台数と顔ぶれ（A の `--check-only` が表示する）
- そのグループを規則の相手にしているグループがあるか（B の `--check-only` が表示する）
- 22 番の規則の中身（相手が CIDR か、セキュリティグループか、すべての通信の規則に含まれていないか）

## 使い方

作業者の PC に AWS CLI（v2）と Ruby 2.6 以上（macOS に入っている Ruby でもよい。標準のライブラリだけ）。認証情報・リージョンは AWS CLI の設定（`AWS_PROFILE`・`AWS_REGION` など）。

```bash
cd sg-ssh-restrict

# A. 規則を直す（標準入力にセキュリティグループの ID を 1 行に 1 つ）
ruby rb/restrict_rule.rb --allow-cidr 203.0.113.0/24 --check-only < group-ids.txt   # 確かめるだけ
ruby rb/restrict_rule.rb --allow-cidr 203.0.113.0/24 --allow-cidr 198.51.100.10/32 < group-ids.txt

# B. 付け替える（標準入力にインスタンスの ID を 1 行に 1 つ）
ruby rb/swap_groups.rb --old-group sg-0123456789abcdef0 --allow-cidr 203.0.113.0/24 --check-only < instance-ids.txt
ruby rb/swap_groups.rb --old-group sg-0123456789abcdef0 --allow-cidr 203.0.113.0/24 < instance-ids.txt

# 元に戻す（A・B が書き出した記録を渡す）
ruby rb/restore.rb sg-change-20261101-120000.json

# 書き方の確認（rubocop を入れるのは初回だけ）
cd rb && bundle install && bundle exec rubocop
```

| 段 | A（`SshRuleRestrict`） | B（`SshGroupSwap`） |
|---|---|---|
| 1 | 22 番の規則を調べて表示する（足す・消す・そのまま・手で直す、付けているインスタンス） | 古いグループの確認（写す規則・除く規則、付け替えられない理由） |
| 2 | — | 付け替えるインスタンスの確認（古いグループが付いていて、ネットワークインターフェースが 1 つ、同じ VPC） |
| 3 | `[y/N]` の確認 | `[y/N]` の確認 |
| 4 | 許可する範囲を足してから、ほかの範囲の 22 番の規則を消す（足せなければ消さない） | 新しいグループの用意（同じ名前があれば使い、なければ作る）→ 1 台ずつ付け替える（`modify-instance-attribute --groups`。ほかのグループはそのまま） |
| 5 | 今の 22 番の規則を表示する | 今付いているグループを表示する |

| 項目 | 内容 |
|---|---|
| 記録 | 既定で `sg-change-<日時>.json`（`--record` で変えられる）。A は足した規則の ID と消した規則、B は付け替えた台の元のグループの一覧と作ったグループ。`restore.rb` に渡す（`.gitignore` で除いている） |
| 元に戻す | A: 消した規則を足し直してから、足した規則を消す。B: 付け替えた台のグループを元の一覧に戻す（作ったグループは消さず、消し方を表示する） |
| 締め出しの備え | 22 番を絞りすぎても、SSM（ssm-setup で有効にした台）なら入れる。先に SSM で入れることを確かめておく |
| 今つながっている SSH | 規則を変えても、すぐには切れないことがある。新しく入り直して確かめる |
| B の写しの送信の規則 | 古いグループの送信の規則をそのまま写す（作ったときの既定のすべて許可は消してから写す）。22 番を絞ったグループは送信の規則を持たない（送信は写しの規則だけが効く） |

作業者の IAM に要る権限: `ec2:DescribeSecurityGroups`、`ec2:DescribeSecurityGroupRules`、`ec2:DescribeNetworkInterfaces`、`ec2:DescribeInstances`。A は `ec2:AuthorizeSecurityGroupIngress`・`ec2:RevokeSecurityGroupIngress`。B は加えて `ec2:CreateSecurityGroup`・`ec2:CreateTags`・`ec2:AuthorizeSecurityGroupEgress`・`ec2:RevokeSecurityGroupEgress`・`ec2:ModifyInstanceAttribute`。

## フォルダの中身

| ファイル | 内容 |
|---|---|
| `rb/restrict_rule.rb` | A. 規則を直す |
| `rb/swap_groups.rb` | B. 付け替える |
| `rb/new_groups.rb` | B が付け替える先の 2 つのグループを用意する |
| `rb/restore.rb` | 記録から元に戻す |
| `rb/security_groups.rb` | セキュリティグループの読み書きの部品（22 番の規則の見分け方、規則の写し方、記録） |
| `rb/lib.rb` | 共通の部品（port-guard-rollout・al2-update の `rb/lib.rb` と、もとは同じもの） |
| `rb/Gemfile`・`rb/.rubocop.yml` | 書き方の確認の rubocop だけを入れる。書き方は rubocop の既定（確かめる版を Ruby 2.6 にしているだけ） |

どのスクリプトも 1 つのクラスで、流れの大枠を公開のメソッドとして上に並べ、ヘルパは `private` の下に分けている。
