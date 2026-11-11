# NLB で 22 番を受けて EC2 の 10022 番へ送り、10022 番を scp・rsync だけにする

> 位置付け: SSH の前段に NLB（Network Load Balancer）を置き、NLB で受けた 22 番を EC2 の 10022 番へ送る形と、EC2 の sshd で 10022 番を scp・rsync などの転送だけに絞る形ができるかの検討メモ。port-guard（80・443 番の絞り込み）とは別の話。
>
> 状態: 検討の段階。NLB の仕様は AWS のドキュメントと照らし合わせた（2026-11-11）。sshd の設定は、Amazon Linux 2 の上で確かめていない。
>
> 作成日: 2026-11-11

## 用語

| 名前 | 指すもの |
|---|---|
| 利用者 | 外から scp・rsync で接続してくる相手 |
| NLB | AWS の Network Load Balancer。TCP の通信を、中身を見ずに後ろへ流す |
| 転送サーバー | NLB の後ろに置く EC2。10022 番で、転送用の接続を受ける |
| 管理用の sshd | 転送サーバーで、今までどおり 22 番で、作業者のログインを受ける sshd |
| 転送用の接続 | 10022 番に来る接続。scp・rsync だけを許す |

## 結論

- **NLB で 22 番を受けて、転送サーバーの 10022 番へ送れる**。リスナーのポート（22）と、ターゲットに送るポート（10022）は別にできる
- **転送サーバーの sshd で、10022 番を scp・rsync だけに絞れる**。同じ sshd の中でポートで分けるか、10022 番専用の sshd を別に動かす
- ただし、22 番以外で受けたいだけなら NLB は要らない。転送サーバーをインターネットに出したくないだけなら、SSM の Session Manager を通す方法もある（下の「NLB が要るか」）

## 1. NLB で 22 番を受けて 10022 番へ送る

| 部分 | 設定 |
|---|---|
| リスナー | TCP の 22 番 |
| ターゲットグループ | TCP、ポートは **10022**、ターゲットの種類はインスタンス（転送サーバーを登録する） |
| 結果 | 利用者からは `ssh -p 22 <NLB の名前>`（`scp`・`rsync` も同じ）。転送サーバーには 10022 番で届く |

| 気を付けること | 内容 |
|---|---|
| 送り元の IP アドレス | ターゲットの種類がインスタンスのときは、既定で利用者の IP アドレスがそのまま転送サーバーに届く（クライアント IP の保持）。そのため転送サーバーのセキュリティグループで、10022 番の送り元に利用者の IP アドレスを許可する。NLB のヘルスチェックの送り元（NLB の VPC の中のアドレス）も許可する |
| 何も流れない時間の上限 | NLB は、既定で 350 秒何も流れない TCP の接続を追わなくなり、その後に送ると接続を切られる（60〜6,000 秒に変えられる）。転送の途中で止まる時間が長いと切れるので、sshd の `ClientAliveInterval`（例: 60 秒）か、利用者の側の `ServerAliveInterval` で、定期的に通信を流す |
| 後ろの転送サーバーが複数台 | 台ごとに sshd のホスト鍵が違うので、接続のたびに違う台へ振られると「ホスト鍵が変わった」という警告が出る。1 台だけを後ろに置くか、ホスト鍵をそろえる |
| ヘルスチェック | TCP のヘルスチェックが 10022 番に定期的に接続するので、sshd の記録に「接続されたが何も送られてこない」という行が残る |
| 22 番を外に開ける | NLB の 22 番をインターネットに開けると、総当たりの接続が来る。NLB のセキュリティグループで、送り元を利用者に絞る |

## 2. 10022 番を scp・rsync だけにする（転送サーバーの sshd）

sshd は `Port 22` と `Port 10022` の両方で待ち受けられる。10022 番に来た接続にだけ制限をかける方法は 2 つある。

| 方法 | 内容 | 利点 | 欠点 |
|---|---|---|---|
| A. 同じ sshd で、ポートで分ける | `/etc/ssh/sshd_config` に `Port 10022` を足し、`Match LocalPort 10022` の中に制限を書く | 設定が 1 つで済む | 書き間違えると、管理用の sshd（22 番）の接続まで巻き込む |
| B. 10022 番専用の sshd を別に動かす | 別の設定ファイル（例: `/etc/ssh/sshd_config_transfer`）と、別の systemd のサービスで動かす | 管理用の sshd と完全に分かれる | サービスと設定が 2 つになる |

10022 番に入れる制限の例（A なら `Match LocalPort 10022` の中、B なら専用の設定ファイルに書く）:

```
AllowUsers transfer                       # 転送用の利用者だけ
PasswordAuthentication no                 # 鍵だけ
PermitTTY no                              # 端末を開かせない
AllowTcpForwarding no                     # ポートフォワーディングをさせない
X11Forwarding no
ClientAliveInterval 60                    # NLB の 350 秒で切られないように
ForceCommand /usr/local/bin/transfer-only # 実行できるコマンドを絞る
```

| 実行できるコマンドの絞り方 | 内容 | 使えるもの |
|---|---|---|
| `ForceCommand` に小さなスクリプト（`transfer-only`） | 利用者が実行しようとしたコマンド（`$SSH_ORIGINAL_COMMAND`）を見て、scp の受け渡し（`scp -t`・`scp -f`）と rsync（`rsync --server ...`）だけを実行し、ほかは断る | scp・rsync |
| 鍵ごとに `rrsync` を指定 | `authorized_keys` の鍵の前に `command="rrsync <置き場所>",restrict` を書く。`rrsync` は rsync に付いてくる、rsync だけを許すスクリプト | rsync だけ |
| `ForceCommand internal-sftp`（と `ChrootDirectory`） | SFTP だけを許す。いちばんかたい | SFTP。scp は利用者の側の OpenSSH が新しければ使える（新しい scp は SFTP で動く）。rsync は使えない |

確かめていないこと:

- Amazon Linux 2 の OpenSSH（7.4 系）で `Match LocalPort` が使えるか。`sudo sshd -T -C lport=10022,user=transfer,host=x,addr=203.0.113.10` で、10022 番に効く設定を表示して確かめる
- `transfer-only` のスクリプトの中身（まだ書いていない）。scp・rsync が実際に送ってくるコマンドの形を、ログで確かめてから書く

## 3. NLB が要るか

| 目的 | 方法 |
|---|---|
| 22 番以外のポートで受けたいだけ | NLB は要らない。転送サーバーの sshd を 10022 番でも待ち受け、セキュリティグループで 10022 番を利用者にだけ開ける（利用者は `ssh -p 10022`） |
| 転送サーバーをインターネットに出したくない（プライベートのサブネットに置く） | NLB を使うか、**SSM の Session Manager を通して ssh する**（`aws ssm start-session --document-name AWS-StartSSHSession` を ssh の `ProxyCommand` に使う）。受けるポートを開けずに、scp・rsync もそのまま使える。ただし利用者に AWS の権限が要るので、社外の相手には向かない |
| 固定の入り口（名前・アドレス）がほしい、複数台に振りたい | NLB が向いている |

## 参考（AWS のドキュメント。2026-11-11 に確かめた）

- [Network Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html)（接続の何も流れない時間の上限: TCP は既定 350 秒、60〜6,000 秒に変えられる。超えた後に送ると TCP の RST が返る）
- [Edit target group attributes for your Network Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html)（クライアント IP の保持: ターゲットの種類がインスタンスなら既定で有効、IP で TCP なら既定で無効）
