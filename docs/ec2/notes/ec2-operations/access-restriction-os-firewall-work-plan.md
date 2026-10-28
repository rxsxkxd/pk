# 作業計画: OS（iptables ＋ ipset）で特定のポートを国内だけに絞る

> 位置付け: [暫定対応: OS（iptables ＋ ipset、または firewalld）で特定のポートを国内と特定の IP に絞る](./access-restriction-os-firewall.md) のうち、**iptables ＋ ipset の案を、今の環境（Amazon Linux 2）のインスタンスに入れるときの作業計画**。設定・スクリプト・ユニットの中身は、そのドキュメントの「手順（iptables ＋ ipset）」を使う。**まだ実施していない**。
>
> 複数台をスクリプトで処理する設計: [設計: 国内だけに絞る設定を複数台に入れるスクリプト](./access-restriction-rollout-script-design.md)
>
> 作成日: 2026-10-28

## 流れ

| 段階 | 内容 | 遮断が効くか |
|---|---|---|
| 0 | 準備（サーバーに触る前） | — |
| 1 | 今の状態の確認（読み取りだけ） | — |
| 2 | **バックアップ**（変更の前に） | — |
| 3 | Session Manager を使える状態にして、接続を確かめる | — |
| 4 | 入れるもの（まだ何も効かせない） | 効かない |
| 5 | 集合だけ作って確かめる | 効かない |
| 6 | **有効化**（自動で元に戻る仕掛けを入れてから） | **ここから効く** |
| 7 | 接続の確認 | 効いている |
| 8 | 定期の更新を有効にする | 効いている |
| 9 | 再起動しても戻るかの確認（保守の時間帯に） | 効いている |
| 10 | 見守りと片付け | 効いている |

どの段階でも、OS の再起動は要らない（9 の確認を除く）。Apache とアプリも再起動しない。

**バックアップを Session Manager より前に置く理由**: Session Manager を使える状態にする作業（SSM Agent を入れる・起動時に有効にする・設定を変える）も、サーバーのディスクへの変更になりうるため、何も変えていない状態を先に残す。AMI は手元の AWS CLI で作れるので、Session Manager の用意を待つ必要もない。なお、インスタンスプロファイルや IAM のロールの変更は AWS の側の設定で、AMI では戻せない（手で戻す）。

## 0. 準備（サーバーに触る前）

| # | 作業 | 内容 |
|---|---|---|
| 0-1 | 対象と許可の決定 | 絞るポート（論点 O1）、破棄か拒否か（O4）、日本以外から通す相手の一覧（海外の拠点、保守の委託先、外形監視、決済などの外部サービスの通知の送り元）（O5） |
| 0-2 | 確認の拠点の用意 | **日本の回線**（許可される側）と、**海外からつなげる場所**（遮断される側。例: 海外のリージョンに一時的な EC2 を立てる） |
| 0-3 | 作業者の道具と権限 | 手元の AWS CLI、Session Manager のプラグイン、IAM の権限（`ssm:StartSession`、`ec2:CreateImage`、インスタンスプロファイルの操作など） |
| 0-4 | スクリプトの用意 | ドキュメントの設定（`port-guard.conf`、`allow.txt`）、2 つのスクリプト、systemd のユニット、cron を、このサーバー向けの値（ポート、許可する IP）にして、レビューしておく |
| 0-5 | 作業の時間帯と連絡 | 止まらない見込みの作業だが、念のため保守の時間帯にして、関係者に知らせる。9 の再起動の確認をするなら、その分の時間も取る |
| 0-6 | 複数台あるなら | まず影響の小さい 1 台で最後まで通してから、残りに広げる |

## 1. 今の状態の確認（読み取りだけ）

| # | 作業 | 内容 |
|---|---|---|
| 1-1 | まとめての確認 | ドキュメントの [事前の確認](./access-restriction-os-firewall.md#全部をまとめて確かめるインスタンスの中で実行) のスクリプトを実行し、結果を残す。iptables のルール・ipset・firewalld が入っていない（効いていない）ことを確かめる。**入っていたら、ここで止めて計画を見直す** |
| 1-2 | 待ち受けているポートと IPv6 | `sudo ss -lntp`、`ip -6 addr show scope global`（IPv6 のアドレスがあれば、IPv6 の扱いを決める） |
| 1-3 | yum が使えるか | `yum info ipset` で、パッケージを取れることを確かめる |
| 1-4 | セキュリティグループ | 対象のポートが開いていること（ここで止まっていれば OS まで届かない）と、送信の 443 番が許可されていること（Session Manager に要る） |
| 1-5 | SSM Agent の状態 | `rpm -q amazon-ssm-agent`、`systemctl is-enabled amazon-ssm-agent`、`systemctl is-active amazon-ssm-agent`（3 で何をするかがここで決まる） |

## 2. バックアップ（変更の前に）

| # | 作業 | 内容 |
|---|---|---|
| 2-1 | 書き込みの反映 | インスタンスの中で `sudo sync`（今の入り方の SSH で行う） |
| 2-2 | AMI | 手元から `aws ec2 create-image --no-reboot`。**`--no-reboot` を必ず付ける**（付けないとインスタンスが再起動される）。取り始めた時点の中身が残るので、完了を待たずに次へ進んでよい |
| 2-3 | インスタンスの外の設定を控える | セキュリティグループ、インスタンスプロファイル（付いているなら、その名前とロールの権限）、Elastic IP、タグ |

```bash
INSTANCE_ID=i-xxxxxxxxxxxxxxxxx
aws ec2 create-image --instance-id "$INSTANCE_ID" --no-reboot \
  --name "<サーバー名>-before-port-guard-$(date +%Y%m%d%H%M)" \
  --description "before port guard (iptables + ipset)"

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{SecurityGroups:SecurityGroups,Profile:IamInstanceProfile.Arn,PublicIp:PublicIpAddress,Tags:Tags}'
```

取れる中身は、電源を急に切ったときと同じ状態（crash-consistent）。設定ファイルやアプリを残す用途なら、`sync` してから取れば十分。

## 3. Session Manager を使える状態にして、接続を確かめる

| # | 作業 | 内容 |
|---|---|---|
| 3-1 | SSM Agent | 1-5 で入っていて動いていれば何もしない。入っていなければ `sudo yum install -y amazon-ssm-agent`、動いていなければ `sudo systemctl enable --now amazon-ssm-agent` |
| 3-2 | 権限 | インスタンスプロファイルがなければ作って付ける（ロールに `AmazonSSMManagedInstanceCore`）。**すでに別のインスタンスプロファイルが付いているなら、付け替えず、そのロールに `AmazonSSMManagedInstanceCore` を足す**（付け替えると、今の権限がなくなる）。どちらも再起動は要らない |
| 3-3 | 登録の確認 | `aws ssm describe-instance-information` で `PingStatus` が `Online`。なかなか `Online` にならなければ `sudo systemctl restart amazon-ssm-agent` |
| 3-4 | 接続の確認 | `aws ssm start-session --target "$INSTANCE_ID"` で入り、`sudo` が使えること、`sudo iptables -S` を実行できることまで確かめる |
| 3-5 | （任意）最後の手段の用意 | SSH のポートを絞るなら、EC2 シリアルコンソールのアカウントでの有効化と、パスワードでログインできるユーザーの作成 |

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion,LastPingDateTime]' --output table
aws ssm start-session --target "$INSTANCE_ID"
```

## 4. 入れるもの（まだ何も効かせない）

| # | 作業 | 内容 |
|---|---|---|
| 4-1 | パッケージ | `sudo yum install -y ipset python3`。`iptables-services` は入れない |
| 4-2 | 入れた直後の状態 | `systemctl is-enabled ipset 2>/dev/null` などで、入れただけで起動時に有効になったものがないか |
| 4-3 | ファイルの配置 | `/etc/port-guard/port-guard.conf`、`/etc/port-guard/allow.txt`、`/usr/local/sbin/port-guard-apply`、`/usr/local/sbin/port-guard-update-jp`、`/etc/systemd/system/port-guard.service`（**`daemon-reload` までで、まだ enable しない**）。cron は**まだ置かない** |
| 4-4 | 日本の IP の範囲の取得 | `sudo /usr/local/sbin/port-guard-update-jp` を 1 回実行する（最後に `--sets-only` で集合も作られるが、ルールはまだないので何も効かない）。`wc -l /etc/port-guard/jp.txt` で件数を見て、最低件数のしきい値（`JP_MIN_ENTRIES`）を見直す |

## 5. 集合だけ作って確かめる（まだ遮断しない）

| # | 作業 | 内容 |
|---|---|---|
| 5-1 | 集合の作成 | `sudo /usr/local/sbin/port-guard-apply --sets-only`（4-4 で作られていれば、作り直しになるだけ）。集合はできるが、ルールから参照されないので、まだ何も効かない |
| 5-2 | 件数 | `sudo ipset list -t`（`port_guard_jp` と `port_guard_allow` の `Number of entries`） |
| 5-3 | 中身の確認 | 日本の回線の IP が `port_guard_jp` に、許可する相手の IP がそれぞれ `port_guard_allow` に入っていること。**海外の確認の拠点の IP が、どちらにも入っていないこと** |
| 5-4 | 遮断のルールがないこと | `sudo iptables -S` に `PORT_GUARD` がまだないこと |

```bash
sudo ipset test port_guard_jp <日本の回線の IP>          # is in set
sudo ipset test port_guard_allow <許可する相手の IP>     # is in set
sudo ipset test port_guard_jp <海外の確認の拠点の IP>    # is NOT in set
sudo ipset test port_guard_allow <海外の確認の拠点の IP> # is NOT in set
```

## 6. 有効化（ここで初めて遮断が効く）

| # | 作業 | 内容 |
|---|---|---|
| 6-1 | 今の状態を控える | `sudo iptables-save > ~/iptables-before-port-guard.txt` |
| 6-2 | 接続を開いたまま | Session Manager のセッション（SSH を使っているならそれも）を開いたままにしておく |
| 6-3 | **自動で元に戻る仕掛け** | 10 分後に遮断のルールを消す予約を入れる。締め出されても、10 分で元に戻る |
| 6-4 | 有効化 | `sudo systemctl enable --now port-guard`。この時点でルールが入る |
| 6-5 | すぐの確認 | 新しい Session Manager のセッションと、日本の回線からの対象のポートへの接続ができること |
| 6-6 | 仕掛けの取り消し | 6-5 で問題がなければ、6-3 の予約を取り消す。**取り消さないと、10 分後に遮断が外れる** |

```bash
# 6-3: 10 分後に遮断のルールを消す予約（<ポート> は port-guard.conf と同じ値）
sudo systemd-run --unit port-guard-auto-revert --on-active=10min \
  /usr/sbin/iptables -D INPUT -p tcp -m multiport --dports <ポート> -j PORT_GUARD

# 6-4
sudo systemctl enable --now port-guard

# 6-6: 予約の取り消し
sudo systemctl stop port-guard-auto-revert.timer
systemctl list-timers | grep port-guard-auto-revert || echo '予約は残っていない'
```

## 7. 接続の確認

| # | 確認 | 期待する結果 |
|---|---|---|
| 7-1 | 日本の回線から対象のポート | つながる |
| 7-2 | 許可した相手から対象のポート | つながる（外部サービスの通知などは、実際に 1 回送ってもらうか、相手の記録を見る） |
| 7-3 | 海外から対象のポート | つながらない（破棄ならタイムアウト） |
| 7-4 | 対象外のポート（ウェブなど） | 今までどおり。アプリの動作も確かめる |
| 7-5 | Session Manager | 新しいセッションで入れる |
| 7-6 | 記録 | `sudo iptables -L PORT_GUARD -n -v` で、各ルールに当たった回数が増えていること。`sudo journalctl -k \| grep 'port-guard drop'` に、7-3 の接続が記録されていること |

```bash
nc -zv -w 5 <ホスト名> <ポート>   # 日本の回線・許可した相手からは成功、海外からはタイムアウト
```

## 8. 定期の更新を有効にする

| # | 作業 | 内容 |
|---|---|---|
| 8-1 | cron を置く | `/etc/cron.d/port-guard`（毎日 4 時台に `port-guard-update-jp`） |
| 8-2 | 翌日の確認 | 更新が動いたか（`sudo journalctl -t port-guard`、`/etc/port-guard/jp.txt` の更新日時、`ipset list -t` の件数） |

## 9. 再起動しても戻るか（保守の時間帯に）

| # | 作業 | 内容 |
|---|---|---|
| 9-1 | 再起動の前 | Session Manager で入れることを確かめておく |
| 9-2 | 再起動 | `sudo systemctl reboot` |
| 9-3 | 戻ったか | `aws ssm describe-instance-information` で `Online`。インスタンスの中で `sudo iptables -S PORT_GUARD`、`sudo ipset list -t`、`systemctl is-active port-guard amazon-ssm-agent`、`sudo journalctl -b -u port-guard` |
| 9-4 | 接続の確認 | 7 の確認をもう一度行う |

再起動しなくても作業は止まらずに済む。ただし、仕組みが再起動の後も働くことは、再起動して初めて確かめられる。ここを省くなら、次に再起動するときに 9-3・9-4 を行う。

## 10. 見守りと片付け

| # | 作業 | 内容 |
|---|---|---|
| 10-1 | 数日の見守り | 破棄の記録と回数を見て、止めてはいけない相手（外部サービス、監視など）が止まっていないか。利用者からの「つながらない」の連絡に注意する |
| 10-2 | 許可する IP の追加 | 漏れがあれば `allow.txt` に足して `sudo /usr/local/sbin/port-guard-apply --sets-only`（ルールは触らず、集合の中身だけが入れ替わる） |
| 10-3 | 記録 | 何を変えたか（足したファイル、ユニット、cron、インスタンスプロファイルとロールの変更）と、確認の結果を残す |
| 10-4 | 確認の拠点の片付け | 0-2 で立てた海外の EC2 などを消す |
| 10-5 | バックアップの片付け | 落ち着いたら（例: 2 週間後）、2-2 の AMI とスナップショットを消す |

## 元に戻す条件と手順

| 状況 | 戻し方 |
|---|---|
| 止めてはいけない接続が止まった（すぐ戻したい） | `sudo iptables -D INPUT -p tcp -m multiport --dports <ポート> -j PORT_GUARD`（ルールを 1 つ消すだけ。止まらない） |
| 特定の相手だけ通したい | `allow.txt` に足して `port-guard-apply --sets-only` |
| 仕組みごと外す | ドキュメントの [外す（元に戻す）](./access-restriction-os-firewall.md#7-外す元に戻す) の手順 |
| 締め出された | 6-3 の予約が残っていれば、10 分後に自動で戻る。それも効かなければシリアルコンソール（3-5 を済ませていれば）、最後は 2-2 の AMI から戻す（戻すときは止まる） |
| Session Manager の権限の変更を戻す | 2-3 で控えた元のインスタンスプロファイルとロールの権限に、手で戻す（AMI には入らない） |
