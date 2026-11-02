# 運用の手順: port-guard を入れた後

> 位置付け: port-guard（80・443 番を国内と許可した IP に絞る iptables ＋ ipset）を**入れて遮断を有効にした後**の運用の手順。最初に入れる手順は [手順](./steps.md)（正本。踏み台サーバーから SSH で入れるなら [踏み台サーバーから入れるコマンド](./bastion-install-commands.md)）、仕組みは [iptables ＋ ipset の仕組みと確認](./iptables-ipset.md)、iptables・ipset そのものの説明は [iptables と ipset の基本](./iptables-ipset-basics.md)。
>
> 状態: 手順の整理。運用中のインスタンスではまだ行っていない。
>
> 更新日: 2026-11-02

## 運用で行うこと

| 場面 | すること | この文書の節 |
|---|---|---|
| ときどき・作業の後 | 遮断が効いているか、集合の件数、破棄の記録を見る | [1. 状態を見る](#1-状態を見る) |
| 許可する相手が増えた・減った | 許可する IP の一覧を入れ替える | [2. 許可する IP を足す・消す](#2-許可する-ip-を足す消す) |
| 日本の IP の範囲を新しくしたい | 範囲を取り直して、集合を入れ替える | [3. 日本の IP の範囲を新しくする](#3-日本の-ip-の範囲を新しくする) |
| 「つながらない」と言われた | 相手の IP が集合に入っているか、捨てられているかを見る | [4. つながらないと言われたとき](#4-つながらないと言われたとき) |
| 一時的に外したい・戻したい | `INPUT` の 1 行を消す・入れ直す | [5. 一時的に外す・戻す](#5-一時的に外す戻す) |
| 再起動・停止と起動・AMI から作った台 | 起動時に入れ直されたかを見る | [6. 再起動と、AMI から作った台](#6-再起動とami-から作った台) |
| もう要らない | 仕組みごと外す | [7. 仕組みごと外す](#7-仕組みごと外す) |

## 道具でできること・できないこと

最初に入れる道具（`install`・`enable`。Python 版 `py/`・sh 版 `sh/`・Ruby 版 `rb/`）は、**遮断を有効にした後の台には使えない**（どの版も「port-guard の遮断がすでに有効になっている」として止まる）。入れた後の一覧の入れ替えは、インスタンスの中のスクリプトで行う。

| インスタンスの中のスクリプト | すること | ルール | 集合 |
|---|---|---|---|
| `/usr/local/sbin/port-guard-apply --sets-only` | `/etc/port-guard/allow.txt`・`jp.txt` から集合を作り直す（`ipset swap` で一瞬で入れ替える） | 触らない | 入れ替える |
| `/usr/local/sbin/port-guard-update-jp` | APNIC から日本の範囲を取り直して `jp.txt` を書き、`port-guard-apply --sets-only` を呼ぶ | 触らない | 入れ替える |
| `/usr/local/sbin/port-guard-apply` | 集合を作り直し、`PORT_GUARD` のチェーンを作り直し、`INPUT` の 1 行がなければ入れる | 入れ直す | 入れ替える |
| `systemctl restart port-guard` | 上の `port-guard-apply` を systemd から呼ぶ（起動時と同じ） | 入れ直す | 入れ替える |

どれも root で実行する。SSM の Run Command（`AWS-RunShellScript`）は root で実行されるので `sudo` は要らない。Session Manager で入ったときは `sudo` を付ける。

日本の範囲の定期的な取り直し（cron など）は、確定した内容ではないので入れていない（[決めること](#決めること)）。

## 複数台に同じコマンドを流す（SSM の Run Command）

この文書のコマンドは、作業者の PC から次の形でまとめて流せる。結果はインスタンスごとに見る。

```bash
ids="i-0123456789abcdef0 i-0fedcba9876543210"   # 対象（フェーズ 1 の ssm-connect-check で入れた台）

command_id=$(aws ssm send-command --document-name AWS-RunShellScript --instance-ids $ids \
  --comment "port-guard status" \
  --parameters 'commands=["iptables -S INPUT | grep -c -- \"-j PORT_GUARD\"","ipset list -t | grep -E \"^Name|entries\""]' \
  --query Command.CommandId --output text)

# しばらく待ってから、結果を見る
aws ssm list-command-invocations --command-id "$command_id" --details \
  --query 'CommandInvocations[].[InstanceId,Status,CommandPlugins[0].Output]' --output text
```

| 点 | 内容 |
|---|---|
| 出力の長さ | `list-command-invocations` で見える出力は、長いと途中で切れる（全部は S3 か CloudWatch Logs に出す設定が要る）。件数や有無だけを出すコマンドにする |
| 引用符 | `--parameters` の中は JSON の文字列なので、コマンドの中の `"` は `\"` にする。長いスクリプトは base64 にして `echo <base64> | base64 -d | bash` の形で送ると崩れない（道具の sh 版・Ruby 版と同じやり方） |
| 権限 | `ssm:SendCommand`（`AWS-RunShellScript`。対象のインスタンスだけに絞る）、`ssm:ListCommandInvocations`、`ssm:GetCommandInvocation` |
| 1 台ずつか、まとめてか | 状態を見るだけならまとめてよい。集合の入れ替えも止まらない操作なのでまとめてよいが、まず 1 台で確かめてから広げる |

## 1. 状態を見る

インスタンスの中で（Session Manager なら `sudo` を付ける）:

```bash
iptables -S INPUT | grep -- '-j PORT_GUARD'          # 遮断が有効か（1 行あれば有効）
iptables -L PORT_GUARD -n -v --line-numbers          # 各ルールに当たった回数（許可・日本・破棄）
ipset list -t port_guard_jp | grep entries           # 日本の範囲の件数（数千件あるはず。0 なら下の「気を付けること」）
ipset list -t port_guard_allow | grep entries        # 許可する IP の件数
systemctl is-enabled port-guard; systemctl is-active port-guard   # 起動時に有効 / 起動時の適用が済んでいる
wc -l /etc/port-guard/jp.txt; stat -c '%y' /etc/port-guard/jp.txt # 日本の範囲のファイルの件数と、取った日時
journalctl -k --since today | grep -c 'port-guard drop'           # 今日の破棄の記録の件数（1 分に 10 件まで）
```

| 見るところ | 正常なとき |
|---|---|
| `INPUT` の 1 行 | 1 行だけある（2 行以上あれば、二重に入っている。害はないが `iptables -D` で 1 つにする） |
| `PORT_GUARD` の回数 | 日本の集合の行が大きく増え、破棄の行もある程度ある |
| 日本の範囲の件数 | `JP_MIN_ENTRIES`（既定 1000）より十分に多い（2026-10 の時点で約 4,700 件） |
| `port-guard` のユニット | `enabled` と `active` |

外からの確認（許可した IP・日本の一般の回線・海外の 3 か所から）は [iptables ＋ ipset の仕組みと確認](./iptables-ipset.md#確かめる)、海外の拠点は [海外からの確認の拠点](./outside-probe.md) を使う。破棄の記録の読み方と数え方は [破棄の記録](./iptables-ipset.md#破棄の記録)。

## 2. 許可する IP を足す・消す

許可する IP の一覧は `/etc/port-guard/allow.txt`（1 行 1 件、CIDR 可、`#` から後はコメント）。書き換えてから、集合だけを入れ替える。**ルールは触らないので、遮断は効いたまま、一瞬で入れ替わる**。

### 1 台で（Session Manager で入って）

```bash
sudo cp -p /etc/port-guard/allow.txt /etc/port-guard/allow.txt.bak-$(date +%Y%m%d%H%M%S)   # 元を残す
sudo vi /etc/port-guard/allow.txt
sudo /usr/local/sbin/port-guard-apply --sets-only
sudo ipset list -t port_guard_allow | grep entries
sudo ipset test port_guard_allow 203.0.113.10        # 足した IP が入ったか（入っていれば終了コード 0）
```

### 複数台に同じ一覧を入れる（作業者の PC から）

一覧の正本は作業者の手元のファイル（`allow.txt`）に置き、全台に同じ中身を入れる（台ごとに手で書き換えると、ずれる）。

```bash
b64=$(base64 < allow.txt | tr -d '\n')
command_id=$(aws ssm send-command --document-name AWS-RunShellScript --instance-ids $ids \
  --comment "port-guard allow list" \
  --parameters "commands=[\"cp -p /etc/port-guard/allow.txt /etc/port-guard/allow.txt.bak-\$(date +%Y%m%d%H%M%S)\",\"echo $b64 | base64 -d > /etc/port-guard/allow.txt\",\"/usr/local/sbin/port-guard-apply --sets-only\",\"ipset list -t port_guard_allow | grep entries\"]" \
  --query Command.CommandId --output text)
aws ssm list-command-invocations --command-id "$command_id" --details \
  --query 'CommandInvocations[].[InstanceId,Status,CommandPlugins[0].Output]' --output text
```

| 点 | 内容 |
|---|---|
| 消すとき | 一覧から行を消して入れ替えれば、その IP は次のパケットから捨てられる（今つながっている接続も止まる） |
| 戻すとき | `allow.txt.bak-<日時>` を `allow.txt` に戻して、もう一度 `port-guard-apply --sets-only` |
| 書き方の誤り | `ipset restore` が読めない行があると、`port-guard-apply` が失敗して、**集合は前の中身のまま**残る（一時的な集合に入れてから入れ替えるため）。終了コードと出力を見る |

## 3. 日本の IP の範囲を新しくする

日本の範囲は、`install` を実行した時点（か、最後に取り直した時点）のもの。APNIC の割り当ては少しずつ変わるので、ときどき取り直す。

```bash
sudo /usr/local/sbin/port-guard-update-jp      # 1 台で
# 複数台には、上の「複数台に同じコマンドを流す」で commands=["/usr/local/sbin/port-guard-update-jp","ipset list -t port_guard_jp | grep entries"]
```

| 点 | 内容 |
|---|---|
| 通り道 | インスタンスから `https://ftp.apnic.net/`（送信の 443 番）に届くこと |
| 取得に失敗したとき | `curl` が失敗すれば、`jp.txt` も集合も変えずに終わる（終了コードが 0 でない） |
| 件数が少なすぎるとき | `JP_MIN_ENTRIES`（既定 1000）より少なければ、集合を入れ替えない（取り直した `jp.txt` は書かれるので、次の「気を付けること」を見る） |
| 記録 | `logger -t port-guard` で、件数を `/var/log/messages` に残す（`journalctl -t port-guard`） |

## 4. つながらないと言われたとき

1. 相手の IP を聞く（相手の回線の「グローバル IP」。会社の VPN を通しているなら VPN の出口の IP）。
2. インスタンスの中で、集合に入っているかを見る。

   ```bash
   sudo ipset test port_guard_allow <相手の IP>
   sudo ipset test port_guard_jp <相手の IP>
   sudo journalctl -k --since '1 hour ago' | grep 'port-guard drop' | grep 'SRC=<相手の IP> '
   ```

3. 判断する。

| 結果 | 考えられること | すること |
|---|---|---|
| どちらの集合にも入っておらず、破棄の記録がある | 海外の回線・VPN・海外のクラウドからの接続 | 必要な相手なら、許可する IP に足す（2） |
| 日本の集合に入っていない日本の回線 | APNIC の統計で、まだ日本の範囲に入っていない（新しく割り当てられた範囲など） | 日本の範囲を取り直す（3）。それでも入らなければ、許可する IP に足す |
| 集合に入っていて、破棄の記録もない | port-guard ではない（セキュリティグループ、ALB、アプリ、証明書など） | port-guard の外を調べる |
| 全員がつながらない | 日本の集合が空、`INPUT` の 1 行が二重以外の形で壊れている、など | 「1. 状態を見る」で件数を見る。急ぐなら一時的に外す（5） |

破棄の記録は 1 分に 10 件までなので、記録にないからといって捨てられていないとは限らない。回数は `iptables -L PORT_GUARD -n -v` の `DROP` の行で見る。

## 5. 一時的に外す・戻す

```bash
# 外す（80・443 番は、すぐに今までどおり通る。ポートは port-guard.conf の値に合わせる）
sudo iptables -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD

# 戻す（集合とチェーンを作り直し、INPUT の 1 行を入れる）
sudo /usr/local/sbin/port-guard-apply
```

| 点 | 内容 |
|---|---|
| 外したままにするか | 外しただけでは、次の再起動で `port-guard.service` が入れ直す。再起動の後も外したままにするなら `sudo systemctl disable port-guard` も行う（戻すときは `sudo systemctl enable port-guard` と `port-guard-apply`） |
| `systemctl start` では戻らないことがある | `port-guard.service` は一回きりのユニット（`RemainAfterExit=yes`）なので、すでに `active` なら `start` は何もしない。戻すときは `port-guard-apply` を直接呼ぶか、`systemctl restart port-guard` |
| `systemctl stop port-guard` | ルールも集合も消さない（止める処理を書いていない）。外すのは上の `iptables -D` |
| 予約つきで試したいとき | 道具の `enable` は、有効にする前に「決めた時間の後に自動で元に戻る」予約を入れる。手で入れ直すときにも同じことをしたいなら、`enable` の流れ（`remote/enable-apply.sh`）を参考にする |

## 6. 再起動と、AMI から作った台

| 場面 | 起きること | 確かめること |
|---|---|---|
| 再起動・停止と起動 | iptables のルールと ipset の集合は消える。起動時に `port-guard.service` が `/etc/port-guard/` のファイルから入れ直す | 「1. 状態を見る」。`journalctl -b -u port-guard` で起動時の適用の記録 |
| この台から作った AMI で起動した台 | `/etc/port-guard/`・スクリプト・有効にしたユニットも AMI に入っているので、**起動した時点で遮断が効く**。一覧は AMI を作った時点のもの | 同じく「1. 状態を見る」。古ければ 2・3 で入れ替える |
| AMI の公開の流れ（`ami-publish`）でリリース用インスタンスから作る AMI | リリース用インスタンスに port-guard を入れていれば、同じく起動時から効く | ヘルスチェックは SSM（送信の 443 番）で行うので、遮断の影響はない |
| OS のパッケージの更新（`yum update`） | 動いているルールと集合は変わらない。`ipset`・`iptables` の更新の後も、次の再起動で入れ直される | 更新の後に再起動したら「1. 状態を見る」 |

**起動時の注意**: 起動時に `jp.txt` の件数が `JP_MIN_ENTRIES` より少ないと、`port-guard-apply` は日本の集合を**空のまま**作り、ルールは入れる。この状態では、許可する IP 以外の日本からの接続もすべて捨てられる。`jp.txt` は、取得に成功したときにしか書き換わらないので普通は起きないが、手で `jp.txt` を触ったときや、取り直しで件数が少なかったときは、再起動の前に件数を確かめる。

## 7. 仕組みごと外す

[iptables ＋ ipset の仕組みと確認の「外す」](./iptables-ipset.md#外す元に戻す) のとおり。ユニットを止めて無効にし、チェーンと集合を消す。ファイル（`/etc/port-guard/`、`/usr/local/sbin/port-guard-*`、`/etc/systemd/system/port-guard.service`）も消すなら、`systemctl daemon-reload` も行う。

## 記録に残すこと

| いつ | 残すこと |
|---|---|
| 許可する IP を変えたとき | 変えた日時、足した・消した IP と理由、対象の台、正本の `allow.txt` の版 |
| 日本の範囲を取り直したとき | 日時と、台ごとの件数 |
| 外した・戻したとき | 日時、理由、対象の台、戻したかどうか |

## 決めること

| 項目 | 内容 |
|---|---|
| 日本の範囲を取り直す頻度 | 手で取り直すか、cron などで定期的に取り直すか（定期的にするなら、取得の失敗と件数の少なさをどう知らせるかも） |
| 許可する IP の一覧の正本の置き場所 | 作業者の手元のファイルか、リポジトリか、S3 などか。誰が変えてよいか |
| 一覧の入れ替えを道具にするか | 今は上のコマンドを手で流す。`install` のように、全台に同じ一覧を入れて結果を表にする道具（`update-lists` など）を足すか |
| 破棄の記録の見守り | CloudWatch に送るか（[破棄の記録](./iptables-ipset.md#破棄の記録)） |
| Let's Encrypt の証明書の更新 | 80 番を国内だけに絞ると、HTTP-01 の確認が失敗する（[気を付けること](./iptables-ipset.md#気を付けること)）。対策は別に決める |
