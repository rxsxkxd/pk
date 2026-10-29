# 暫定対応: OS（iptables ＋ ipset、または firewalld）で特定のポートを国内と特定の IP に絞る

> 位置付け: 今の環境（Amazon Linux 2・Apache 2.4.56・Passenger・Rails 4.2・Ruby 2.7.7）に入れる**暫定対応**の検討。AL2023 での作り直し（[今の構成を AL2023 で作り直す検討](../../initial-image-build/existing-system-rebuild-on-al2023.md)）とは別に考える。**動かして確かめてはいない**。
>
> 同じ要件のほかの層: [Apache で絞る](./access-restriction-apache.md)、[アプリ（Rails）で絞る](./access-restriction-rails-app.md)
>
> 作業の手順（iptables ＋ ipset の案。採用）: [port-guard-rollout の手順](../../port-guard-rollout/steps.md)
>
> 作成日: 2026-10-28

## 要件

特定のポートについて、**国内（日本）からのアクセスは全体を許可し、海外からのアクセスはすべて絞る**。数件の IP を許可するだけでは足りないので、国で判定することが本命になる。日本以外から通す必要がある少数の相手（海外の拠点、外部サービス、外形監視など）は、**許可する IP** として補助的に足す。絞った接続は破棄する。

## 結論

| # | 結論 |
|---|---|
| 1 | 暫定対応には **iptables ＋ ipset** を勧める。対象のポートだけにルールを足すので、ほかのポートに影響せず、外すのも簡単 |
| 2 | **iptables のサービス（`iptables-services`）は使わない**。既定の設定ファイルは SSH 以外をすべて拒否する内容なので、有効にするとウェブのポートまで閉じる。ルールは自前の小さなスクリプトと systemd のユニットで入れる |
| 3 | **firewalld は OS のファイアウォール全体を引き受ける仕組み**で、有効にした時点で、許可していないポートがすべて閉じる。使うなら、今開いているポートを洗い出して先に許可してから有効にする |
| 4 | OS で絞ると、HTTP 以外のポート（SSH など）も含めて、Apache やアプリに届く前に止められる。国の判定には、日本の IP の範囲の一覧（数千件）を使い、cron で定期的に取り直す |

## iptables ＋ ipset の詳細（移した）

iptables ＋ ipset の案は採用が決まり、詳細は道具の側に移した。

| 内容 | 移した先 |
|---|---|
| 仕組み、日本の IP の範囲の取り方、事前の確認（すでに入っているか・有効か、Session Manager で入れるか、受信のポートを全部閉じた場合）、入れて有効にするときの挙動、手で確かめる・外す方法 | [iptables ＋ ipset の仕組みと確認](../../port-guard-rollout/iptables-ipset.md) |
| 作業の手順（複数台をまとめて行う道具の使い方） | [手順](../../port-guard-rollout/steps.md) |

確定した内容: 絞るのは **80・443 番だけ**（SSH の 22 番は絞らない）。SSM の導入を前提にする。

## firewalld を使う場合

firewalld がどういう仕組みで、どういう場面に向いているかは [補足: firewalld とは何か](./firewalld-overview.md)。

### iptables ＋ ipset との違い

| 項目 | iptables ＋ ipset（自前のスクリプト） | firewalld |
|---|---|---|
| 範囲 | 対象のポートだけ | **OS のファイアウォール全体**。有効にした時点で、ゾーンで許可していないポートはすべて閉じる（`public` ゾーンの既定で開いているのは SSH などだけ） |
| ほかのルールとの関係 | 既存のルールに足すだけ | firewalld が iptables のルールを自分で管理する。手で足したルールとは併用しない |
| 一覧の扱い | `ipset restore` と `ipset swap` で速く入れ替えられる | ipset を firewalld に登録する。数千件の入れ替えは、ファイルを書き換えて `firewall-cmd --reload` で読み直すことになる |
| 向いている場面 | 暫定対応で、影響を対象のポートに限りたいとき | OS のファイアウォールを、これを機に全体として管理したいとき |

### 手順の要点

有効にした瞬間に閉じるポートが出ないよう、**`firewall-offline-cmd` で、止めたまま設定を済ませてから起動する**。

```bash
sudo yum install -y firewalld
systemctl is-enabled firewalld   # 入れただけで enabled になっていないか（なっていれば、設定を済ませるまで次の再起動をしない）

# 今開いているポートを洗い出し、残すものを先に許可する（例: HTTP と HTTPS）
sudo ss -lntp
sudo firewall-offline-cmd --zone=public --add-service=http --add-service=https

# 集合を作り、中身を入れる
sudo firewall-offline-cmd --new-ipset=port_guard_jp --type=hash:net --option=family=inet --option=maxelem=65536
sudo firewall-offline-cmd --ipset=port_guard_jp --add-entries-from-file=/etc/port-guard/jp.txt
sudo firewall-offline-cmd --new-ipset=port_guard_allow --type=hash:net --option=family=inet
sudo firewall-offline-cmd --ipset=port_guard_allow --add-entries-from-file=/etc/port-guard/allow.txt

# 対象のポート（例: 8443）は、2 つの集合からだけ受け付ける
sudo firewall-offline-cmd --zone=public --add-rich-rule='rule family="ipv4" source ipset="port_guard_allow" port port="8443" protocol="tcp" accept'
sudo firewall-offline-cmd --zone=public --add-rich-rule='rule family="ipv4" source ipset="port_guard_jp" port port="8443" protocol="tcp" accept'

sudo firewall-offline-cmd --list-all   # 設定を見直してから
sudo systemctl enable --now firewalld
```

| 点 | 内容 |
|---|---|
| 対象が SSH のとき | `public` ゾーンは既定で SSH（サービス `ssh`）を誰にでも許可している。SSH を絞るなら、ゾーンから `ssh` を外し（`--remove-service=ssh`）、上の rich rule のポートを 22 にする |
| `allow.txt` のコメント | `--add-entries-from-file` が `#` のコメントを読み飛ばすかは要確認。だめなら、コメントを除いたファイルを渡す |
| 一覧の更新 | 更新のスクリプトの最後を、集合の定義のファイル（`/etc/firewalld/ipsets/port_guard_jp.xml`）を書き換えて `firewall-cmd --reload` する形に変える |
| 外す | `systemctl disable --now firewalld`。止めると firewalld のルールはすべて消え、すべて受け付ける状態に戻る |

## 気を付けること

iptables ＋ ipset の案での注意（Let's Encrypt の更新への影響、位置の判定、IPv6 など）は、[iptables ＋ ipset の仕組みと確認の「気を付けること」](../../port-guard-rollout/iptables-ipset.md#気を付けること) に移した。

## 決めること

| # | 論点 | 選択肢 |
|---|---|---|
| O1 | 対象のポート | 例: SSH（22）、管理用のポート、HTTPS（443） |
| O2 | iptables ＋ ipset か firewalld か | 暫定対応なら iptables ＋ ipset（勧める） / 全体を管理したいなら firewalld |
| O3 | 日本の IP の範囲の取得元 | APNIC の割り当ての統計（勧める） / MaxMind GeoLite2 |
| O4 | 破棄か拒否か | 破棄（`DROP`） / 拒否（`REJECT`） |
| O5 | 許可する IP の一覧 | 事務所、保守の委託先、監視、外部サービスなど |

## 参考

- [APNIC の割り当ての統計](https://ftp.apnic.net/stats/apnic/)（`delegated-apnic-latest` と、その形式の説明）
- [ipset(8)](https://ipset.netfilter.org/ipset.man.html)（`hash:net`、`restore`、`swap`）
- [firewalld の文書](https://firewalld.org/documentation/)（ipset、rich rule、`firewall-offline-cmd`）
- [Let's Encrypt のチャレンジの種類](https://letsencrypt.org/docs/challenge-types/)（HTTP-01 の確認は 80 番に来る）
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)（受信のポートを開けずに入れる仕組み）、[EC2 シリアルコンソール](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-serial-console.html)
