# 暫定対応: OS（iptables ＋ ipset、または firewalld）で特定のポートを国内と特定の IP に絞る

> 位置付け: 今の環境（Amazon Linux 2・Apache 2.4.56・Passenger・Rails 4.2・Ruby 2.7.7）に入れる**暫定対応**の検討。AL2023 での作り直し（[今の構成を AL2023 で作り直す検討](../../initial-image-build/existing-system-rebuild-on-al2023.md)）とは別に考える。**動かして確かめてはいない**。
>
> 同じ要件のほかの層: [Apache で絞る](./access-restriction-apache.md)、[アプリ（Rails）で絞る](./access-restriction-rails-app.md)
>
> 作業計画（iptables ＋ ipset の案）: [作業計画: OS（iptables ＋ ipset）で特定のポートを国内だけに絞る](./access-restriction-os-firewall-work-plan.md)
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

## 仕組み

```
接続 → INPUT チェーン
         └ 対象のポート → PORT_GUARD チェーン
                              ├ ループバック（同じマシンの中）      → 受け付ける
                              ├ 許可する IP の集合（port_guard_allow）→ 受け付ける
                              ├ 日本の IP の集合（port_guard_jp）     → 受け付ける
                              ├ 記録（回数を絞って）
                              └ 破棄
         └ 対象外のポート → 今までどおり（何もしない）
```

| 部品 | 内容 |
|---|---|
| ipset の集合 | `hash:net` 型。CIDR を数千件入れても、照合は速い。`port_guard_allow`（許可する IP）と `port_guard_jp`（日本の IP の範囲）の 2 つ |
| iptables のチェーン | 自前のチェーン `PORT_GUARD` を作り、INPUT の先頭から「対象のポートならこのチェーンへ」と飛ばす。ほかのルールに混ぜないので、外すときは飛ばすルールを消すだけでよい |
| 一覧のファイル | `/etc/port-guard/allow.txt`（許可する IP。担当者が書く）と `/etc/port-guard/jp.txt`（日本の IP の範囲。更新のスクリプトが書く） |
| 適用のスクリプト | `/usr/local/sbin/port-guard-apply`。集合を作って中身を入れ、ルールを入れる。起動時に systemd から呼ぶ |
| 更新のスクリプト | `/usr/local/sbin/port-guard-update-jp`。日本の IP の範囲を取り直し、集合の中身だけを入れ替える。cron から毎日呼ぶ |

集合の中身の入れ替えは、一時的な集合に新しい中身を入れてから `ipset swap` で入れ替える。入れ替えは一瞬で済み、途中で空になる時間がない。

## 日本の IP の範囲の取り方

| 取得元 | 内容 | 向き不向き |
|---|---|---|
| **APNIC の割り当ての統計**（`delegated-apnic-latest`） | 無料、登録なし、毎日更新。IP アドレスが**どの国の組織に割り当てられたか** | 暫定対応に向く。実際に使われている場所とは限らない（海外の拠点に割り当てた範囲など） |
| MaxMind GeoLite2 Country（CSV） | 無料だがアカウントとライセンスキーが要る。週 2 回更新。**位置の推定**で精度が高い | 精度を上げたいとき。Apache やアプリで絞る場合（[Apache](./access-restriction-apache.md)・[アプリ](./access-restriction-rails-app.md)）と同じ取得元にそろえられる |

APNIC の統計の 1 行は `apnic|JP|ipv4|1.0.16.0|4096|20110412|allocated` の形で、「先頭のアドレス」と「個数」で範囲を表す。個数が 2 のべき乗とは限らないので、CIDR への変換には Python の `ipaddress` を使う（`python3` がなければ `yum install -y python3`）。

## 事前の確認: すでに入っているか・有効になっているか

iptables ＋ ipset、firewalld、Session Manager は、入っていない前提で手順を書いている。ただし、運用中のインスタンスによっては、誰かが入れて有効にしている可能性がある。**手を入れる前に、インスタンスごとに次の確認をする**。どのコマンドも読み取りだけで、設定は変えない。

### 「有効」の見分け方

「有効かどうか」は、次の 4 つを分けて見る。特に、**起動時の有効と今の動作がずれている状態**は、再起動のときに挙動が変わるので見落とさない。

| 段階 | 意味 | 見るもの |
|---|---|---|
| 入っている | パッケージがある | `rpm -q <パッケージ>` |
| 起動時に有効 | 再起動のときに自動で動き出す | `systemctl is-enabled <ユニット>` が `enabled`（`disabled` なら自動では動かない、`masked` なら起動できないようにされている） |
| 今動いている | 今この時点で動いている | `systemctl is-active <ユニット>` が `active`（`inactive` なら止まっている） |
| ルールが効いている | カーネルにルールや集合が入っている | `iptables -S`、`ipset list`、`firewall-cmd --list-all` の中身。**サービスが入っていなくても、手でルールを入れていれば効いている** |

| ずれ | 起きること |
|---|---|
| 起動時に有効だが、今は止まっている | **次の再起動で動き出し、ポートが閉じる**ことがある（特に firewalld と、`iptables-services` の既定の設定） |
| 今は動いているが、起動時に有効ではない | 再起動するとルールが消える |
| サービスはないが、ルールが入っている | 誰かが手で入れたか、ほかのソフトウェア（Docker など）が入れたもの。再起動で消えるか、別の仕組みで入れ直されている |

### 全部をまとめて確かめる（インスタンスの中で実行）

```bash
sudo bash <<'EOS'
section() { printf '\n===== %s =====\n' "$1"; }
unit_state() {
  local enabled active
  enabled=$(systemctl is-enabled "$1" 2>/dev/null); active=$(systemctl is-active "$1" 2>/dev/null)
  printf '%-22s 起動時=%-10s 今=%s\n' "$1" "${enabled:-ユニットなし}" "${active:-ユニットなし}"
}

section 'パッケージ'
rpm -q iptables iptables-services ipset ipset-service firewalld amazon-ssm-agent

section 'サービス（起動時に有効か / 今動いているか）'
for unit in iptables ip6tables ipset firewalld amazon-ssm-agent docker fail2ban; do unit_state "$unit"; done

section 'iptables（今カーネルに入っているルール）'
iptables -V
for table in filter nat mangle raw; do echo "--- $table"; iptables -t "$table" -S; done
echo "--- ip6tables filter"; ip6tables -S
ls -l /etc/sysconfig/iptables /etc/sysconfig/ip6tables 2>&1

section 'ipset（今カーネルに入っている集合）'
if command -v ipset >/dev/null; then ipset list -t; else echo 'ipset のコマンドなし'; fi
ls -l /etc/sysconfig/ipset 2>&1
echo "--- iptables から参照している集合"; iptables -S | grep -- '--match-set' || echo 'なし'

section 'firewalld'
if command -v firewall-cmd >/dev/null; then
  firewall-cmd --state
  if firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --get-active-zones
    firewall-cmd --list-all
    firewall-cmd --get-ipsets
    firewall-cmd --direct --get-all-rules
  fi
else
  echo 'firewall-cmd のコマンドなし'
fi

section 'カーネルのモジュール'
lsmod | grep -E '^(ip_tables|ip6_tables|iptable_|ip_set|xt_set|nf_tables|nf_conntrack) ' || echo 'なし'

section 'SSM Agent（Session Manager）'
rpm -q amazon-ssm-agent
command -v ssm-cli >/dev/null && ssm-cli get-diagnostics --output table
tail -n 20 /var/log/amazon/ssm/amazon-ssm-agent.log 2>/dev/null
token=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
echo "--- インスタンスプロファイル"
curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/iam/info || true
echo
EOS
```

### 結果の読み方

| 対象 | 入っていない・効いていない状態 | 注意が要る状態 |
|---|---|---|
| iptables | `iptables-services` が「インストールされていない」。`iptables -S` が `-P INPUT ACCEPT`・`-P FORWARD ACCEPT`・`-P OUTPUT ACCEPT` の 3 行だけ（ほかの表も同様） | `-A` で始まる行がある（ルールが効いている）。`iptables` のユニットが `enabled` で、`/etc/sysconfig/iptables` がある（再起動のときにそのファイルのルールが入る。既定の内容は SSH 以外を拒否する） |
| ipset | `ipset` のコマンドがないか、`ipset list -t` が何も表示しない | 集合がある。iptables から `--match-set` で参照されている。`ipset` のユニットが `enabled`（再起動のときに `/etc/sysconfig/ipset` から集合が入る） |
| firewalld | `firewalld` が「インストールされていない」、または `firewall-cmd --state` が `not running` で、ユニットが `disabled` | `running`（ゾーンで許可していないポートは閉じている。`--list-all` で許可しているサービスとポートを見る）。**ユニットが `enabled` で今は `not running`**（次の再起動で動き出す） |
| ほかに iptables を触るもの | `docker`・`fail2ban` のユニットがない | Docker は `nat` の表などに自分のルールを入れる。fail2ban は遮断のルールを足す。どちらも、自前のルールと並べて動かすときに確かめる |
| カーネルのモジュール | — | `nf_tables` が読み込まれていれば、nftables のルールが入っている可能性がある（`sudo nft list ruleset` で見る。コマンドがなければ使われていない） |

`iptables -V` の表示に `(nf_tables)` とあれば、iptables のコマンドは裏で nftables を使っている。`(legacy)` か何も付かなければ、昔ながらの iptables である。

### Session Manager で入れるか

Session Manager で入れるには、**インスタンスの側（SSM Agent が動き、AWS の窓口に届く）と、AWS の側（マネージドノードとして登録されている）**の両方がそろっている必要がある。

インスタンスの中で見るもの（上のまとめての確認に含めた）:

| 見るもの | 入れる状態 |
|---|---|
| `rpm -q amazon-ssm-agent` | 入っている（AL2 の AMI には最初から入っている） |
| `amazon-ssm-agent` のユニット | 起動時に有効で、今動いている |
| `ssm-cli get-diagnostics` | すべての項目が成功（AWS の窓口への接続、インスタンスのメタデータ、認証情報）。`ssm-cli` は新しめの SSM Agent にしかない |
| エージェントのログ | 認証情報が取れない、窓口につながらない、といった誤りが繰り返し出ていない |
| インスタンスプロファイル | `InstanceProfileArn` が表示される。404 ならインスタンスプロファイルがない（ただし、下の「既定のホスト管理の設定」が有効なら、なくても登録される） |

手元の PC（AWS CLI）で見るもの:

```bash
INSTANCE_ID=i-xxxxxxxxxxxxxxxxx

# マネージドノードとして登録されているか（PingStatus が Online なら入れる見込み）
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion,LastPingDateTime]' --output table

# インスタンスプロファイルと、そのロールに AmazonSSMManagedInstanceCore が付いているか
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query 'IamInstanceProfileAssociations[].IamInstanceProfile.Arn' --output text
aws iam get-instance-profile --instance-profile-name <インスタンスプロファイルの名前> \
  --query 'InstanceProfile.Roles[].RoleName' --output text
aws iam list-attached-role-policies --role-name <ロールの名前> --output table

# 既定のホスト管理の設定（インスタンスプロファイルなしでも登録させる設定）が有効か
aws ssm get-service-setting \
  --setting-id "arn:aws:ssm:<リージョン>:<アカウント ID>:servicesetting/ssm/managed-instance/default-ec2-instance-management-role"

# 実際に入ってみる（手元に Session Manager のプラグインが要る）
aws ssm start-session --target "$INSTANCE_ID"
```

| 結果 | 意味 |
|---|---|
| 一覧に出ない | マネージドノードとして登録されていない。SSM Agent が動いていない、権限がない（インスタンスプロファイルも既定のホスト管理の設定もない）、AWS の窓口に届かない、のどれか |
| `PingStatus` が `ConnectionLost` | 以前は登録されていたが、今はつながっていない |
| `Online` | 登録されている。`start-session` で実際に入れることまで確かめれば確実 |

ネットワークの面では、インスタンスから AWS の窓口（`ssm`・`ssmmessages`・`ec2messages`）へ HTTPS（443 番）で出られる必要がある。インターネットに出られるか、VPC エンドポイントがあれば届く。セキュリティグループの受信の許可は要らない。Session Manager の使い方は [SSM Session Manager による EC2 運用](./ssm-session-manager-operations.md)。

### 補足: 受信のポートを全部閉じても、Session Manager でメンテナンスできるか

**できる**。Session Manager は、インスタンスの SSM Agent の方から AWS の窓口（`ssm`・`ssmmessages`・`ec2messages`）へ HTTPS で接続を張る仕組みで、外からの受信の口は要らない。セキュリティグループでも OS のファイアウォールでも、受信を全部閉じたまま入れる。ただし、SSM Agent が動いていることに加えて、次の条件がそろっている必要がある。

| # | 条件 | 「全閉じ」にするときに崩しやすい点 |
|---|---|---|
| 1 | SSM Agent が動いていて、**マネージドノードとして登録されている**（`PingStatus` が `Online`） | 権限（インスタンスプロファイルの `AmazonSSMManagedInstanceCore`、または既定のホスト管理の設定）がないと、動いていても登録されない |
| 2 | インスタンスから AWS の窓口へ、**送信の 443 番**で出られる | セキュリティグループの送信、ネットワーク ACL、OS の送信のルール（`OUTPUT`）で 443 番まで止めないこと。経路は、インターネット（パブリック IP か NAT ゲートウェイ）か VPC エンドポイント |
| 3 | **送信した接続の戻りの通信**を受け取れる | OS のファイアウォールで受信を全部破棄にするなら、確立済みの接続の戻りを通すルールが要る（iptables なら `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`）。これがないと、受信を閉じた瞬間に SSM Agent もつながらなくなる。セキュリティグループは戻りを自動で通すが、ネットワーク ACL は通さないので、戻りの一時的なポート（1024〜65535）の受信の許可が要る |
| 4 | 名前の解決とインスタンスのメタデータに届く | OS のファイアウォールで、DNS（VPC の DNS への 53 番）と、メタデータ（`169.254.169.254`。認証情報を取る）を止めないこと |
| 5 | 入る側の権限と道具 | 操作する人の IAM に `ssm:StartSession` などがあり、手元に Session Manager のプラグインがある |

このドキュメントの形（対象のポートだけを専用のチェーンで絞る）なら、ほかの通信に触らないので、3 と 4 は崩れない。崩しやすいのは、「受信を全部破棄」のように OS で広く閉じる場合である。

受信を閉じたままでもできること:

| 作業 | 方法 |
|---|---|
| シェルでの作業 | `aws ssm start-session` |
| ファイルのやり取り | Session Manager の上で SSH を通す（`sshd` と鍵は要るが、22 番を外に開ける必要はない）か、S3 を経由する |
| ウェブの画面などの確認 | Session Manager のポートフォワード（インスタンスの中の 443 番などを手元に転送する） |
| コマンドの一括実行 | Run Command |

**SSM Agent そのものが動かなくなると入れない**（ディスクが一杯、メモリが尽きた、OS が固まった、エージェントの更新に失敗した、権限を外した、など）。受信を閉じたままの最後の手段は次の 2 つで、どちらも事前の用意が要る。

| 手段 | 事前に要ること |
|---|---|
| EC2 シリアルコンソール | アカウントでの有効化、Nitro のインスタンスタイプ（t3a は対象）、**OS にパスワードでログインできるユーザー**（事前に作っておかないと使えない） |
| ルートボリュームを外して、別のインスタンスで直す | 止めてもよい時間 |

EC2 Instance Connect は 22 番の受信が要るので、全閉じでは使えない。

まとめると、「SSM Agent が登録済みで、送信の 443 番と戻りの通信、DNS、メタデータが通る」なら、受信を全部閉じてもメンテナンスできる。エージェントが倒れたときに備えて、シリアルコンソールの用意（パスワードのあるユーザー）まで済ませておく。

### 入れて有効にするとき: 再起動の要否と、効き始める時点

入っていない環境に iptables・ipset・firewalld・SSM Agent を入れて有効にするときの、再起動の要否と、いつから効くか（いつ効かなくなるか）をまとめる。資料からの整理で、AL2 の実機では確かめていない。

#### 再起動は要らない

| 対象 | 入れて有効にする操作 | 再起動 | 補足 |
|---|---|---|---|
| iptables | 最初から入っている（`iptables` のコマンド）。ルールを足せばその場で効く | 不要 | `iptables-services` で保存・復元するなら `systemctl enable --now iptables`。ただし既定の設定ファイルは SSH 以外を拒否する内容なので、このドキュメントでは使わない |
| ip6tables | 同上（IPv6 用） | 不要 | IPv6 を使っているときだけ関係する |
| ipset | `yum install -y ipset` | 不要 | 必要なカーネルのモジュール（`ip_set`、`xt_set`）は、集合を作ったときやルールから参照したときに自動で読み込まれる |
| firewalld | `yum install -y firewalld` → `systemctl enable --now firewalld` | 不要 | 起動した瞬間に効く（下の表）。だから、止めたまま `firewall-offline-cmd` で設定を済ませてから起動する |
| SSM Agent | AL2 には最初から入っている。なければ `yum install -y amazon-ssm-agent` → `systemctl enable --now amazon-ssm-agent` | 不要 | 動いているインスタンスにも、インスタンスプロファイルを後から付けられる（付け替えも再起動は不要） |
| （参考）EC2 シリアルコンソール | アカウントでの有効化と、パスワードでログインできるユーザーの作成 | 不要 | AL2 の AMI は、最初からシリアルコンソールに出力する設定になっている |

例外として、カーネルを更新した後でまだ再起動していないと、今動いているカーネル用のモジュールが見つからないことがある。ただし、yum は今動いているカーネルを消さないので、普通は起きない。

#### 効き始める時点と、効かなくなる時点

**常駐するプロセスがあるのは firewalld と SSM Agent だけ**。iptables と ipset はプロセスではなく、コマンドでカーネルに入れたルールや集合が、その時点から効く。

| 対象 | 常駐するプロセス | 効き始める時点 | 効かなくなる時点 |
|---|---|---|---|
| iptables（コマンドで足したルール） | **ない** | `iptables` のコマンドでルールを足した瞬間（効くのはカーネルの中のルール） | ルールを消したとき。**再起動するとすべて消える**（起動時に入れ直す仕組みがなければ） |
| iptables（`iptables-services`） | **ない**（`iptables.service` は、設定ファイルを読み込んで終わる一回きりのユニット） | `systemctl start iptables` で `/etc/sysconfig/iptables` を読み込んだ瞬間。**既定の内容なら、ここで SSH 以外の受信が拒否される** | `systemctl stop iptables` か `restart` のとき。**止めると、手で足したものも含めてすべてのルールが消え、すべて受け付ける状態に戻る**（このドキュメントの `PORT_GUARD` のルールも消える） |
| ipset | **ない** | `ipset create` で集合を作った瞬間に集合ができる。ただし**集合だけでは何も起きず、iptables のルールから参照されて初めて効く** | 集合を消したとき（参照しているルールがあると消せない）。**再起動するとすべて消える**（起動時に入れ直す仕組みがなければ） |
| firewalld | **ある**（`firewalld`） | **プロセスが起動した瞬間**にゾーンの設定が入り、許可していないポートが閉じる。**それまでに手で入れた iptables のルールは、firewalld が置き換える**（このドキュメントの `PORT_GUARD` と併用できないのはこのため） | 止めたとき。既定では、止めるとルールを片付けて、すべて受け付ける状態に戻る |
| SSM Agent | **ある**（`amazon-ssm-agent`） | **プロセスの起動だけでは使えない**。起動した後に、インスタンスのメタデータから認証情報を取り、AWS に登録されて（`PingStatus` が `Online`）初めて入れる。権限がないと、起動していても試し直しを続けるだけ | 止めたとき（今つながっているセッションも切れる）。エージェントの自動更新や再起動のときも、セッションは切れる |

#### firewalld の「今だけの設定」と「保存した設定」

firewalld の設定には、**今効いている設定（runtime）** と **保存した設定（permanent）** の 2 つがある。取り違えると、「効いていると思ったら再起動で消えた」「保存したのに効いていない」が起きる。

| 操作 | 今効くか | 再起動や `--reload` の後も残るか |
|---|---|---|
| `firewall-cmd <変更>`（`--permanent` なし） | 効く | **残らない**（`--reload` や再起動で消える） |
| `firewall-cmd --permanent <変更>` | **効かない**（`--reload` するまで） | 残る |
| `firewall-offline-cmd <変更>`（止めたまま） | —（止まっている） | 残る（起動したときに効く） |
| `firewall-cmd --runtime-to-permanent` | — | 今効いている設定を保存する |

確実なのは、`--permanent` で変えてから `firewall-cmd --reload` で効かせる手順。今効いている設定は `firewall-cmd --list-all`、保存した設定は `firewall-cmd --permanent --list-all` で見比べられる。

#### SSM Agent が使えるようになるまで

| 状況 | 使えるようになる時点 |
|---|---|
| インスタンスプロファイルがあり、エージェントを起動した | 起動から数十秒〜数分で `Online` になる |
| エージェントが動いている状態で、後からインスタンスプロファイルを付けた | エージェントが認証情報を取り直すまで待つ（試し直しの間隔が延びていると、数分以上かかることがある）。`systemctl restart amazon-ssm-agent` で早められる |
| 既定のホスト管理の設定（インスタンスプロファイルなしで登録させる設定）を使う | 設定を有効にした後、エージェントが試し直すまで待つ。新しめの SSM Agent と、IMDSv2 が使えることが要る |
| 送信の 443 番、DNS、インスタンスのメタデータのどれかが止まっている | 使えない（[補足: 受信のポートを全部閉じても](#補足-受信のポートを全部閉じてもsession-manager-でメンテナンスできるか) の条件） |

使えるかどうかは、エージェントのプロセスではなく、手元の `aws ssm describe-instance-information` の `PingStatus`（`Online`）と、実際の `aws ssm start-session` で確かめる。

#### インストールしただけで動き出すか

`yum install` では、普通はサービスは**起動しない**。ただし、パッケージによっては**入れただけで「起動時に有効」になる**ことがある（systemd の preset という仕組み）。たとえば firewalld が「起動時に有効、今は止まっている」状態になると、**次の再起動で動き出し、ポートが閉じる**。AL2 の firewalld・`iptables-services`・`ipset-service` がそうなるかは確かめていないので、**入れた直後に必ず状態を見る**。

```bash
# 入れた直後に見る（起動時に有効か / 今動いているか）
systemctl is-enabled firewalld iptables ip6tables ipset amazon-ssm-agent
systemctl is-active  firewalld iptables ip6tables ipset amazon-ssm-agent
```

意図せず `enabled` になっていたら、使わないものは `systemctl disable <ユニット>` で戻す。

#### 運用中に気を付ける操作

| 操作 | 起きること |
|---|---|
| `systemctl restart iptables`（`iptables-services` が入っている場合） | すべてのルールが消えてから `/etc/sysconfig/iptables` が読み込まれる。**手で足したルール（`PORT_GUARD` など）は消える** |
| `service iptables save` | 今のルールで `/etc/sysconfig/iptables` を上書きする。次に `iptables.service` が動いたとき、保存した時点のルールが入る（`PORT_GUARD` のルールも保存されるが、参照している ipset の集合が先にないと読み込みに失敗する） |
| `systemctl start firewalld` | 手で入れた iptables のルールが firewalld のものに置き換わる |
| `firewall-cmd --reload` | 保存した設定を読み直す。`--permanent` なしで足した設定は消える |
| Docker の起動・再起動 | Docker が自分の iptables のルール（`nat` の表など）を入れ直す。自前のルールの並び順に影響することがある |
| 再起動 | iptables のルールと ipset の集合は消える。起動時に入れ直す仕組み（このドキュメントでは `port-guard.service`）があるものだけが戻る |

#### 再起動の後も効いているかの確かめ方

入れた直後に効いていても、次の再起動で戻らない、あるいは思わぬものが動き出すことがある。**保守の時間帯に一度再起動して**、次を確かめるのが確実。

```bash
sudo iptables -S PORT_GUARD                   # ルールが戻っているか
sudo ipset list -t                            # 集合が戻っているか（件数）
systemctl is-active port-guard firewalld amazon-ssm-agent
sudo journalctl -b -u port-guard              # 起動時の適用の記録
```

あわせて、手元から `aws ssm describe-instance-information` で `Online` に戻ったことと、外から対象のポートの許可と遮断が以前と同じであることを確かめる。

## 手順（iptables ＋ ipset）

### 0. 事前の確認

[事前の確認: すでに入っているか・有効になっているか](#事前の確認-すでに入っているか有効になっているか) を済ませ、iptables・ipset・firewalld が入っていない（効いていない）ことを確かめる。入っていたら、その仕組みに合わせて手順を見直す（firewalld が動いていれば、下の「firewalld を使う場合」で進める）。あわせて次を見る。

```bash
sudo ss -lntp                    # 待ち受けているポート
ip -6 addr show scope global     # IPv6 のアドレスがあるか（あるなら ip6tables も要る。下の「IPv6」）
```

SSH のポートを絞るなら、締め出しに備えて、Session Manager かシリアルコンソールで入れることを先に確かめる（[Session Manager で入れるか](#session-manager-で入れるか)）。

### 1. パッケージ

```bash
sudo yum install -y ipset python3
systemctl is-enabled ipset 2>/dev/null   # ipset のサービスのユニットがあれば、起動時に有効になっていないか
```

`iptables` のコマンドは最初から入っている。`iptables-services` は入れない（結論の 2）。

### 2. 設定と一覧のファイル

```bash
sudo mkdir -p /etc/port-guard

# 対象のポート（複数ならカンマで区切る）
echo 'PORT_GUARD_PORTS=8443' | sudo tee /etc/port-guard/port-guard.conf

# 許可する IP（1 行 1 件。CIDR でもよい。# から後はコメント）
sudo tee /etc/port-guard/allow.txt <<'EOF'
203.0.113.10        # 例: 事務所
198.51.100.0/24     # 例: 保守の委託先
10.0.0.0/16         # 例: 同じ VPC の中（監視など）
EOF
```

### 3. 適用のスクリプト

```bash
sudo tee /usr/local/sbin/port-guard-apply <<'EOS'
#!/bin/bash
# 対象のポートを、許可する IP と日本の IP の範囲からだけ受け付ける。
# --sets-only: 集合の中身だけを入れ替える（ルールは触らない）
set -euo pipefail
source /etc/port-guard/port-guard.conf
ALLOW_FILE=/etc/port-guard/allow.txt
JP_FILE=/etc/port-guard/jp.txt
JP_MIN_ENTRIES="${JP_MIN_ENTRIES:-1000}"   # これより少なければ、取得の失敗とみなして入れ替えない（port-guard.conf で変えられる）

# ファイルの中身で集合を作り直す（一時的な集合に入れてから swap する）
load_set() {
  local name=$1 file=$2 tmp="${1}_tmp"
  ipset create -exist "$name" hash:net family inet maxelem 65536
  ipset create -exist "$tmp" hash:net family inet maxelem 65536
  ipset flush "$tmp"
  sed 's/#.*//' "$file" | awk -v set="$tmp" 'NF { print "add " set " " $1 }' | ipset restore -exist
  ipset swap "$tmp" "$name"
  ipset destroy "$tmp"
}

jp_entries=$(grep -cvE '^\s*(#|$)' "$JP_FILE" || true)
if [ "$jp_entries" -lt "$JP_MIN_ENTRIES" ]; then
  echo "port-guard: $JP_FILE has only $jp_entries entries; keep the current set" >&2
  ipset create -exist port_guard_jp hash:net family inet maxelem 65536
else
  load_set port_guard_jp "$JP_FILE"
fi
load_set port_guard_allow "$ALLOW_FILE"

[ "${1:-}" = "--sets-only" ] && exit 0

iptables -N PORT_GUARD 2>/dev/null || true
iptables -F PORT_GUARD
iptables -A PORT_GUARD -i lo -j ACCEPT
iptables -A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
iptables -A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
iptables -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
iptables -A PORT_GUARD -j DROP

rule=(INPUT -p tcp -m multiport --dports "$PORT_GUARD_PORTS" -j PORT_GUARD)
iptables -C "${rule[@]}" 2>/dev/null || iptables -I "${rule[0]}" 1 "${rule[@]:1}"
EOS
sudo chmod 755 /usr/local/sbin/port-guard-apply
```

| 点 | 内容 |
|---|---|
| 日本の一覧が少なすぎるとき | 取得に失敗した可能性があるので、今の集合のまま残す（空の一覧で入れ替えると、全員を締め出す） |
| チェーンを作り直す一瞬 | `iptables -F PORT_GUARD` から破棄のルールを足し終えるまでの一瞬は、チェーンが空で、対象のポートが開く側に倒れる（締め出す側には倒れない）。起動時と設定の変更時だけで、毎日の更新（`--sets-only`）では起きない |
| 同じマシンの中 | ループバック（`lo`）からの接続は常に受け付ける |

### 4. 日本の IP の範囲の更新のスクリプト

```bash
sudo tee /usr/local/sbin/port-guard-update-jp <<'EOS'
#!/bin/bash
# APNIC の割り当ての統計から日本の IPv4 の範囲を取り直し、集合の中身を入れ替える
set -euo pipefail
URL=https://ftp.apnic.net/stats/apnic/delegated-apnic-latest
JP_FILE=/etc/port-guard/jp.txt
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsS --max-time 120 -o "$work/delegated" "$URL"
python3 - "$work/delegated" > "$work/jp.txt" <<'EOF'
import ipaddress, sys
for line in open(sys.argv[1]):
    f = line.strip().split('|')
    if len(f) >= 7 and f[1] == 'JP' and f[2] == 'ipv4' and f[6] in ('allocated', 'assigned'):
        start = ipaddress.IPv4Address(f[3])
        end = start + int(f[4]) - 1
        for network in ipaddress.summarize_address_range(start, end):
            print(network)
EOF

install -m 644 "$work/jp.txt" "$JP_FILE"
/usr/local/sbin/port-guard-apply --sets-only
logger -t port-guard "updated $JP_FILE: $(wc -l < "$JP_FILE") entries"
EOS
sudo chmod 755 /usr/local/sbin/port-guard-update-jp

sudo /usr/local/sbin/port-guard-update-jp   # 初回の取得（この時点ではまだルールは入らない）
wc -l /etc/port-guard/jp.txt                 # 件数を見て、JP_MIN_ENTRIES を見直す
```

### 5. 起動時の適用（systemd）と、毎日の更新（cron）

```bash
sudo tee /etc/systemd/system/port-guard.service <<'EOF'
[Unit]
Description=Restrict specific ports to Japan and allowed IP addresses
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/port-guard-apply

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now port-guard    # ここでルールが入る

# 毎日 4 時台に日本の IP の範囲を取り直す（分は適当にずらす）
echo '17 4 * * * root /usr/local/sbin/port-guard-update-jp' | sudo tee /etc/cron.d/port-guard
```

### 6. 確認

```bash
sudo iptables -L PORT_GUARD -n -v --line-numbers   # 各ルールに当たった回数
sudo ipset list -t port_guard_jp                   # 集合の件数（Number of entries）
sudo ipset test port_guard_jp 1.0.16.1             # ある IP が日本の集合に入っているか
sudo journalctl -k | grep 'port-guard drop'        # 破棄した接続の記録（/var/log/messages にも出る）
```

外からの確認は、許可した IP、日本の一般の回線、海外（例: 海外のリージョンの EC2）の 3 か所から行う。

```bash
nc -zv -w 5 <ホスト名> 8443     # 海外からはタイムアウトする（破棄なので、拒否の応答も返らない）
```

### 7. 外す（元に戻す）

```bash
# すぐに外す（ルールを消すだけで、対象のポートは今までどおりになる）
sudo iptables -D INPUT -p tcp -m multiport --dports 8443 -j PORT_GUARD

# 仕組みごと外す
sudo systemctl disable --now port-guard
sudo rm -f /etc/cron.d/port-guard
sudo iptables -F PORT_GUARD && sudo iptables -X PORT_GUARD
sudo ipset destroy port_guard_jp && sudo ipset destroy port_guard_allow
```

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

| 点 | 内容 |
|---|---|
| Let's Encrypt の更新 | **80 番のポートを国で絞ると、証明書の更新（HTTP-01 の確認）が失敗する**。Let's Encrypt は複数の国から確認の接続を行うため。80 番を絞るなら、Apache の側で `/.well-known/acme-challenge/` だけを開ける形（[Apache で絞る](./access-restriction-apache.md)）にし、OS では 80 番を絞らない |
| 位置の判定は完全ではない | 海外にいる日本の利用者、VPN、海外のクラウドや外形監視のサービス、決済などの外部サービスからの通知（webhook）は「日本以外」になりうる。必要な相手は `allow.txt` に足す |
| 破棄と拒否 | 破棄（`DROP`）は応答を返さないので、相手には「つながらない（タイムアウト）」に見える。拒否（`REJECT`）にすると、すぐに「拒否された」と分かる。どちらにするかは、相手にサーバーの存在を見せたいかで決める |
| IPv6 | インスタンスに IPv6 のアドレスがあり、セキュリティグループが IPv6 を通しているなら、`ip6tables` と `family inet6` の集合で同じことをするか、対象のポートの IPv6 をまとめて破棄する |
| セキュリティグループとの関係 | セキュリティグループで対象のポートを開けていることが前提（セキュリティグループで止まった接続は、OS まで届かない）。IP だけで足りるポートは、セキュリティグループで絞る方が簡単 |
| 記録の量 | 破棄の記録は 1 分に 10 件までに絞っている。攻撃が多いと、記録は一部だけになる。数は `iptables -L PORT_GUARD -n -v` の回数で見る |

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
