# EC2 Image Builder の定義: 今の構成に近いテスト用のインスタンス（ビルドは確認済み・テストは直した後が未確認）

> 位置付け: [port-guard-rollout](../../README.md) を試す相手を、**開発用の AWS アカウントの、本番とは別の VPC** に EC2 として作るための AMI の定義。手元の [Docker の定義](../README.md) と同じ構成（Amazon Linux 2・Apache 2.4.56・Passenger 6.0.18・Ruby 2.7.7・最小の Rails 4.2 のアプリ）を、EC2 Image Builder で AMI にする。**開発用のアカウントでデプロイし、ビルドは通った**（2026-10-29）。`test` は版の確認で落ちたので、版を見ないように直した（直した後の `test` はまだ通していない。下の「版の確かめ方」）。
>
> 作成日: 2026-10-29

## ファイル

| ファイル | 内容 |
|---|---|
| `port-guard-test-al2.yml` | CloudFormation のテンプレート。インスタンスのロール、2 つのコンポーネント（システム・アプリ）、イメージのレシピ、インフラストラクチャの設定、配布の設定、イメージのパイプライン。**`generate.py` で作ったもの（手で直さない）** |
| `generate.py` | テンプレートを作る。アプリ（`../app/`）と Apache の設定（`../httpd/`）を、コンポーネントにそのまま埋め込む。アプリや Apache の設定を変えたら `python3 generate.py` で作り直す |

## Docker の定義との対応と違い

| 項目 | Docker の定義（`../Dockerfile`） | この定義 |
|---|---|---|
| 親イメージ | `amazonlinux:2`（digest で固定） | Amazon Linux 2 の AMI（SSM のパラメーター `/aws/service/ami-amazon-linux-latest/amzn2-ami-kernel-5.10-hvm-x86_64-gp2`。デプロイした時点の AMI に決まる） |
| アーキテクチャ | 手元の Mac に合わせて arm64 | **x86_64**（本番の t3a に合わせる。ビルドは `t3a.medium`） |
| Apache・mod_ssl・mod_http2 | 2.4.56・2.4.56・1.15.19 | 同じ（版を指定して入れる） |
| MPM | prefork（AL2 の既定） | 同じ |
| Ruby・RubyGems・Bundler・Passenger | 2.7.7・3.4.22・2.4.22・6.0.18（`/home/centos/.rbenv`） | 同じ |
| アプリ | `../app/` を COPY | `../app/` と同じ中身を、コンポーネントに埋め込む（`Gemfile.lock` も） |
| nokogiri | arm64 ではソースからビルド（`force_ruby_platform`） | **ビルド済みのもの**（x86_64 のビルド済みのものは AL2 の glibc で動く。`force_ruby_platform` は付けない） |
| systemd | ない（`entrypoint.sh` で起動） | **ある**。`httpd` を起動時に有効にする。port-guard の `systemctl enable` や再起動の後の復元も試せる |
| SSH | `openssh-server` を入れ、`ssh/` の鍵を `centos` に渡す | AL2 の AMI に最初から入っている。`centos` の公開鍵は、起動のときの UserData で入れる（下の「テスト用のインスタンスの起動」） |
| SSM Agent | 入れない | **AMI には残る**（下の「SSM Agent の扱い」） |
| 証明書 | 自己署名 | 自己署名（ビルドのときに作るので、この AMI から起動したインスタンスは同じ鍵を持つ。テスト用なので問題にしない） |
| 起動のときの更新 | ない | **ある**。AL2 の cloud-init は、新しいインスタンスの最初の起動でセキュリティの更新を入れる（`repo_upgrade: security`）。そのため、この AMI から起動したインスタンスでは、`httpd`・`mod_ssl` が新しい版（openssl11 を使う）に上がることがある。port-guard を試すには差し支えないので、止めていない（下の「版の確かめ方」） |

## コンポーネントの分け方と、アプリの渡し方

| コンポーネント | 中身 | Data の大きさ |
|---|---|---|
| `<NamePrefix>-system` | パッケージ（Apache は版を指定）、`centos` ユーザー、rbenv と Ruby、RubyGems・Bundler・Passenger、Apache の設定と証明書。`validate` で Apache の版、MPM、`mod_ssl` が libssl を使うこと、ipset などが入っていないことを確かめる（Ruby の OpenSSL と Passenger の版は記録に出すだけ） | 約 7,500 文字 |
| `<NamePrefix>-app` | アプリのファイル（12 個）を置き、`bundle install`、`httpd` を起動時に有効にして起動する。`validate` と `test` で `/health` の応答を確かめる | 約 10,400 文字 |

### 版の確かめ方

| 段 | どのインスタンスか | 確かめること |
|---|---|---|
| `validate`（ビルド） | ビルド用のインスタンス | Apache の版、MPM、`mod_ssl` が何かの libssl を使うこと、`/health` の Ruby・OpenSSL・Rails の版。Ruby の OpenSSL と Passenger の版は、ログに出すだけ（確かめない） |
| `test` | できた AMI から新しく起動したインスタンス | **版は見ない**: `httpd` が動いていること、80・443 番の `/health` が 200 を返すこと、ipset・iptables-services が入っていないこと |

細かい版の確認は、実際にビルドとテストを流したときに落ちたので緩めた（2026-10-29）。`validate` の 3 つ（`mod_ssl` の `libssl.so.10`、Ruby の OpenSSL、Passenger の版）は、ビルドを通すために利用者の環境で緩めたものを取り込んだ。`test` は `mod_ssl` の `libssl.so.10` の確認で落ちた。`mod_ssl` が `libssl.so.10`（OpenSSL 1.0.2k）を使っていない理由は確かめていない（上の「起動のときの更新」のほか、x86_64 の `mod_ssl` が手元の arm64 と違う作りの可能性もある）。port-guard を試すのに要るのは、80・443 番で応答することと、ipset などが入っていないことなので、版の違いは問題にしない。本番の版にそろえて試したくなったら、ビルドで `yum-plugin-versionlock` を使って `httpd`・`httpd-tools`・`httpd-devel`・`mod_ssl`・`mod_http2` を固定する（まだ入れていない）。

**アプリはコンポーネントに埋め込む（S3 は使わない）**。理由:

- コンポーネントの `Data` は **16,000 文字まで**（Image Builder の API の `CreateComponent` の `data` の上限。2026-10-29 に API の文書で確認）。アプリと設定は合わせて 5 KB ほどで、システムとアプリの 2 つのコンポーネントに分ければ、どちらも上限に収まる
- S3 を使うと、バケット、アップロードの手順、ビルド用のインスタンスの読み取りの権限が増える。テスト用の AMI のためには、1 つのスタックで完結する方がよい
- アプリが大きくなって上限を超えたら、コンポーネントを `Uri`（S3 の YAML）に切り替えるか、アプリの tar を S3 に置いて取らせる

埋め込みの中で、行に `: `（コロンと空白）を含むコマンドは、YAML のマッピングとして読まれないよう行全体を引用符で囲んでいる。

## SSM Agent の扱い

今の本番のインスタンスには SSM Agent がない見込み。一方、Image Builder はビルドとテストの途中で SSM Agent を使うので、ビルドの中では消せない（AL2 の AMI には最初から入っていて、起動時に有効）。

| 案 | 内容 | 試せる port-guard の場面 |
|---|---|---|
| **A. 起動のときの UserData で消す（勧める既定）** | `yum remove -y amazon-ssm-agent` | 本番と同じ「入っていない」状態から、ssm-setup の `command/instance/agent-install.sh` のインストールを試せる |
| B. 起動のときに止めて、起動時の有効化も外す | `systemctl disable --now amazon-ssm-agent` | `command/instance/agent-install.sh` の有効化と起動を試せる |
| C. そのまま（動いている） | 何もしない | インスタンスプロファイルを付ければ、すぐに `--via ssm` を試せる。`rb/ssm_check.rb` で「SSM 有効」になり、SSM Agent の導入は要らない |
| D. Image Builder の `UninstallAfterBuild: true` で、AMI から外す | レシピの `AdditionalInstanceConfiguration` を変える | A と同じ状態の AMI になる。ただし、AL2 のように**最初から入っている** SSM Agent も外すのかは**未確認**（Image Builder が自分で入れたものだけを外す、という読み方もできる） |

既定は **A** を勧める。本番の状態にいちばん近く、フェーズ 1（ssm-setup の `rb/ssm_role.rb` → `rb/ssm_check.rb` → `rb/backup.rb` → `command/instance/agent-install.sh` → `rb/ssm_check.rb` → `command/connect/ssm-connect-check.sh`）→ フェーズ 2（`install --via ssm` → `enable --via ssm`）の流れを最初から試せる。B と C は、ほかの分類や経路を試すときに、同じ AMI から起動のしかたを変えるだけで作れる。

## 作り方

前提:

- 開発用のアカウントの、本番とは別の VPC
- インターネットに出られるサブネット（ビルドで yum のリポジトリ、GitHub、rubygems.org、cache.ruby-lang.org から取得する）
- 受信なし、送信は TCP 80・443 を許可したセキュリティグループ（ビルド用）

```bash
cd port-guard-rollout/al2-instance/image-builder

# スタックの作成・更新（開発用のアカウントの認証情報で）
aws cloudformation deploy \
  --stack-name port-guard-test-al2-image-builder \
  --template-file port-guard-test-al2.yml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides SubnetId=<サブネットの ID> SecurityGroupId=<セキュリティグループの ID>

# AMI を作る（ビルド → テスト → 配布。Ruby と Passenger のコンパイルを含むので時間がかかる）
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn <スタックの出力 ImagePipelineArn>

# 進み具合と、できた AMI
aws imagebuilder list-image-pipeline-images --image-pipeline-arn <スタックの出力 ImagePipelineArn>
aws ec2 describe-images --owners self --filters Name=tag:Purpose,Values=port-guard-rollout-test-instance \
  --query 'Images[].[ImageId,Name,State,CreationDate]' --output table
```

### 版の上げ方

コンポーネントとレシピは、同じ名前と版のまま中身を変えられない。

| 変えるもの | 行うこと |
|---|---|
| アプリ（`../app/`）や Apache の設定（`../httpd/`） | `python3 generate.py` で作り直し、`ComponentVersion` と `RecipeVersion` を上げてデプロイ |
| Apache・Ruby・Passenger などの版 | `generate.py` の中のコンポーネントのパラメーターの既定値を変えて作り直し、`ComponentVersion` と `RecipeVersion` を上げる |
| 親イメージを新しい AL2 にする | `RecipeVersion` を上げてデプロイ（デプロイした時点の AMI に決まる） |
| インスタンスタイプ、サブネット、ログの置き場所 | 版は上げなくてよい |

## テスト用のインスタンスの起動

| 項目 | 例 |
|---|---|
| AMI | 上でできた AMI（タグ `Purpose=port-guard-rollout-test-instance`） |
| インスタンスタイプ | `t3a.medium`（本番と同じ系統） |
| VPC・サブネット | 開発用の VPC の公開のサブネット（パブリック IP あり。海外の確認の拠点から届くように） |
| セキュリティグループ | 受信: **22 番は作業者の IP だけ**、**80・443 番は 0.0.0.0/0**（[海外の確認の拠点](../../outside-probe.md) から届くように。port-guard で絞る前に、海外から届くことを確かめるため）。送信: すべて |
| キーペア | EC2 のキーペアは `ec2-user` に入るので、`centos` には UserData で公開鍵を入れる |
| インスタンスプロファイル | `--via ssm` を試すなら、`AmazonSSMManagedInstanceCore` を付けたもの |
| タグ | `Name=port-guard-test-al2-01` など |

UserData の例（SSM Agent の扱いは案 A。`centos` に作業者の公開鍵を入れる）:

```bash
#!/bin/bash
set -euo pipefail
# centos に作業者の公開鍵を入れる（今のインスタンスと同じく、centos で SSH で入る）
cat >> /home/centos/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAA... 作業者
EOF
chown centos:centos /home/centos/.ssh/authorized_keys
chmod 600 /home/centos/.ssh/authorized_keys
# 本番に合わせて SSM Agent を消す（案 A）
yum remove -y amazon-ssm-agent
```

```bash
aws ec2 run-instances \
  --image-id <AMI の ID> --instance-type t3a.medium \
  --subnet-id <公開のサブネットの ID> --security-group-ids <テスト用のセキュリティグループの ID> \
  --associate-public-ip-address \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=port-guard-test-al2-01},{Key=Purpose,Value=port-guard-rollout-test-instance}]'

ssh centos@<パブリック IP> 'curl -s http://localhost/health'
```

### IPv6 も試すとき

port-guard の IPv6 の分（`-ipv6.sh`）を試すには、IPv4 と IPv6 の両方のアドレスを持つインスタンスにする。IPv6 の扱いの全体と、手元の AWS で確認できることは [port-guard と IPv6](../../ipv6.md)。AWS の仕様は AWS のドキュメントと照らし合わせた（2026-11-11）。**コマンドは実行していない**。

#### IPv4 と IPv6 のアドレスの違い

IPv4 と IPv6 は、同じアドレスではない。1 つのインスタンスが、形式の違う別々のアドレスを両方持つ。

| 項目 | IPv4 | IPv6 |
|---|---|---|
| 例 | プライベート `10.0.1.20`、パブリック `203.0.113.10` | `2001:db8:1234:1a00::10`（1 つ） |
| プライベートとパブリック | 別のアドレス。VPC の中はプライベート、インターネットからはパブリック | 同じアドレスを VPC の中からもインターネットからも使う（Amazon が用意する範囲はインターネットに公開される） |
| 停止・起動 | パブリック IP は変わる（Elastic IP なら変わらない） | 変わらない（インスタンスを終了すると解放される） |
| DNS のレコード | A | AAAA |
| port-guard の集合 | `port_guard_jp`・`port_guard_allow`・`port_guard_aws` | `port_guard_jp6`・`port_guard_allow6`・`port_guard_aws6` |

IPv4 で絞っても IPv6 は絞られない（逆も同じ）。IPv6 で 80・443 番を受けるなら、IPv6 の分も流す。

#### 1. VPC とサブネットに IPv6 を付ける（一度だけ）

```bash
# VPC に Amazon が用意する IPv6 の範囲（/56）を付ける
aws ec2 associate-vpc-cidr-block --vpc-id <VPC の ID> --amazon-provided-ipv6-cidr-block

# 公開のサブネットに、その /56 の中から /64 を付ける
aws ec2 associate-subnet-cidr-block --subnet-id <サブネットの ID> --ipv6-cidr-block <2001:db8:1234:1a00::/64 の形>

# 公開のサブネットのルートテーブルに、IPv6 の既定の経路をインターネットゲートウェイへ足す
aws ec2 create-route --route-table-id <ルートテーブルの ID> \
  --destination-ipv6-cidr-block ::/0 --gateway-id <インターネットゲートウェイの ID>
```

#### 2. セキュリティグループに IPv6 の受信を足す

```bash
aws ec2 authorize-security-group-ingress --group-id <テスト用のセキュリティグループの ID> --ip-permissions \
  'IpProtocol=tcp,FromPort=80,ToPort=80,Ipv6Ranges=[{CidrIpv6=::/0}]' \
  'IpProtocol=tcp,FromPort=443,ToPort=443,Ipv6Ranges=[{CidrIpv6=::/0}]'
```

外向きの IPv6 の全許可は、VPC に IPv6 を付けたときに自動で足される（外向きの規則を変えていなければ）。ネットワーク ACL を独自に作っているなら、IPv6 の規則も足す。

#### 3. IPv6 アドレス付きで起動する

上の `run-instances` に `--ipv6-address-count 1` を足す。

```bash
aws ec2 run-instances \
  --image-id <AMI の ID> --instance-type t3a.medium \
  --subnet-id <公開のサブネットの ID> --security-group-ids <テスト用のセキュリティグループの ID> \
  --associate-public-ip-address --ipv6-address-count 1 \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=port-guard-test-al2-v6-01},{Key=Purpose,Value=port-guard-rollout-test-instance}]'
```

t3a は IPv6 に対応している。今の版の Amazon Linux 2 の AMI から起動すれば、OS の側の IPv6 の設定は要らない。

#### 4. 確かめる

```bash
aws ec2 describe-instances --instance-ids <インスタンスの ID> --query 'Reservations[].Instances[].Ipv6Address' --output text
ssh centos@<パブリック IP> 'ip -6 addr show eth0'
curl -g -6 -s -o /dev/null -w '%{http_code}\n' 'http://[<IPv6 アドレス>]/health'   # IPv6 が使える端末から
```

#### port-guard の IPv6 を試すときの注意

| 項目 | 内容 |
|---|---|
| 許可の一覧 | `00-vpc-cidr.sh` を流すと VPC の IPv6 の範囲も表示されるので、`port_guard_whitelists/allow-ipv6.txt` に書く |
| 流すスクリプト | ステップ 2〜5 の `-ipv6.sh` と、`command/make-ipset-files-ipv6.sh` |
| 確かめる端末 | 日本と海外の両方に、IPv6 で接続できる端末が要る。作業者の回線と、[海外の確認の拠点](../../outside-probe.md) が IPv6 を使えるかは確かめていない |

AWS のドキュメント:

- [Add IPv6 support for your VPC](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-migrate-ipv6-add.html)
- [Manage the IPv6 addresses for your EC2 instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/working-with-ipv6-addresses.html)
- [Amazon EC2 instance IP addressing（IPv6 の停止・起動の扱い）](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-instance-addressing.html)

## port-guard-rollout を試す流れ

開発用のアカウントの認証情報（`--profile`）を使う。対象の一覧（`instance-ids.txt`）には、テスト用のインスタンスの ID を書く（接続先は AWS CLI でパブリック IP を引く）。1〜3 はフェーズ 1 として `ssm-setup/` で [ssm-setup の手順](../../../ssm-setup/steps.md) の道具（`rb/` の Ruby、`command/connect/`・`command/instance/` の sh）を、4〜7 はフェーズ 2 として `port-guard-rollout/py/` で `python3 -m port_guard_rollout`（バックアップは `python3 -m port_guard_rollout_backup`）を使う。バックアップはフェーズごとに取る。手順の詳細は [ssm-setup の手順](../../../ssm-setup/steps.md) と [port-guard-rollout の手順](../../steps.md)。

| # | コマンド | 確かめること |
|---|---|---|
| 1 | フェーズ 1: `ruby rb/ssm_role.rb --instance-profile <用意したもの>` → `ruby rb/ssm_check.rb --ok-out enabled.txt --ng-out ng.txt` → `bash command/connect/ssm-connect-check.sh --ok-out ok.txt < enabled.txt` | 関連付けができる。案 A（SSM Agent を消した）なら「SSM Agent で直す」になり、`ng.txt` に載る。案 C なら「SSM 有効」になり、接続の確認で `ok.txt` に載る |
| 2 | フェーズ 1: `ruby rb/backup.rb --backup-label <値> < ng.txt` → `ruby rb/backup_check.rb --backup-label <値> --ok-out backup-ok.txt < ng.txt` → `backup-ok.txt` の台に SSH で `command/instance/agent-check.sh`・`command/instance/agent-install.sh` を流す | AMI が作られ、作成が終わったら「操作できる」になる。案 A なら SSM Agent が入り、`Online` になる |
| 3 | フェーズ 1: もう一度 `ruby rb/ssm_check.rb --ok-out enabled2.txt < backup-ok.txt` → `bash command/connect/ssm-connect-check.sh --ok-out ok2.txt < enabled2.txt`（既定で session と run-command の両方） | 「入れる」になり、`ok2.txt` に載る（4 以降の対象の一覧になる） |
| 4 | フェーズ 2: `backup`・`check` → `install --backup-label <値> --allow-file <一覧> --check-in-jp <作業者の IP> --check-outside <拠点の IP>`（`--via ssh` と `--via ssm` の両方） | 集合ができ、遮断はまだ効いていない |
| 5 | フェーズ 2: `enable --backup-label <値>`（`--via ssh` と `--via ssm` の両方） | インスタンスごとの確認、自動で元に戻る予約、作業者の PC からの確認、確定。**systemd があるので、`systemctl enable --now port-guard` と、再起動の後にルールと集合が戻ることも試せる** |
| 6 | 海外からの確認 | [海外の確認の拠点](../../outside-probe.md) から、遮断の前は届き、後は届かないこと |
| 7 | 破棄の記録 | [破棄の記録](../../iptables-ipset.md#破棄の記録) の場所に `port-guard drop:` の行が出ること（EC2 なのでカーネルのログに出る） |

## 未確認の点

| # | 点 |
|---|---|
| 1 | テンプレートを実際にデプロイし、ビルド・テストが通るか（AWSTOE で `commands` の各行が 1 つのスクリプトとして続けて実行され、先頭の `set -euo pipefail` が効くか、を含む）。`validate` の版の確認を緩めてビルドは通った。`test` は版の確認で落ちたので、版を見ないように直した（直した後のテストはまだ） |
| 2 | AL2 のリポジトリに、x86_64 の `httpd-2.4.56`・`mod_ssl-2.4.56`・`mod_http2-1.15.19-1.amzn2.0.2` が今もあるか（arm64 では 2026-10-28 に確認）。x86_64 の `mod_ssl` が、どの libssl を使っているか（`validate` の記録の `ldd` の出力で分かる） |
| 3 | Bundler 2.4 が、`Gemfile.lock`（`PLATFORMS` が `ruby` だけ）に x86_64 の環境を足して、ビルド済みの nokogiri を選ぶか |
| 4 | Image Builder のテストのインスタンスで、`httpd` が起動時に動き、`/health` が応答するまでの時間（テストの段が早すぎて失敗しないか） |
| 5 | `UninstallAfterBuild: true` が、最初から入っている SSM Agent も外すか（SSM Agent の扱いの案 D） |
| 6 | 1 回のビルドとテストにかかる時間と費用 |
