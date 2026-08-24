# 補足: bash プロンプト等のシェル環境カスタマイズの自動化

> スコープ: CloudFormation で作成する EC2 インスタンス（Linux）で、bash のプロンプト、エイリアス、履歴設定、ホスト名、タイムゾーンなどのログイン環境を UserData / cfn-init で自動設定する方法
>
> スコープ外: OS のユーザー管理全般、Windows のシェル環境
>
> 関連: [EC2 へのファイル配備 — CloudFormation + S3 + UserData](./cfn-s3-userdata-provisioning.md) / [補足: UserData・cfn-init の実行権限（root / sudo）](./userdata-cfn-init-privileges.md)

## 結論

**まかなえる。** bash のプロンプトやエイリアスなどの設定は、実体はすべて設定ファイルである。root で動く UserData や cfn-init の `files` でファイルを配置すれば、そのまま反映される（[実行権限の補足](./userdata-cfn-init-privileges.md)）。

ただし次の点に注意する。

| # | 注意点 | 対応 |
|---|---|---|
| 1 | `/etc/skel` を変更しても ec2-user には効かない | 全ユーザー向けは `/etc/profile.d/`、ec2-user 個別は `~ec2-user/.bashrc` を直接編集する |
| 2 | Session Manager では既定で `sh` が起動し、bash の設定が効かない | Session Manager のシェルプロファイルまたは Run As を設定する |
| 3 | 既存のログインセッションには反映されない | 再ログインまたは `source` する |
| 4 | UserData は初回起動時にしか実行されない | 稼働中インスタンスへの変更は SSM / cfn-hup / インスタンス置換で反映する |

## 前提知識: bash の設定ファイルの読み込み順

Amazon Linux / RHEL 系での主な読み込み経路は次のとおり。

| シェルの種類 | 読み込まれるファイル |
|---|---|
| ログインシェル（SSH ログイン、`su -`、`bash -l`） | `/etc/profile` → `/etc/profile.d/*.sh` → `~/.bash_profile` → `~/.bashrc` → `/etc/bashrc` |
| 非ログインの対話シェル（ログイン後に `bash` を起動した場合など） | `~/.bashrc` → `/etc/bashrc` → `/etc/profile.d/*.sh` |

どちらの経路でも `/etc/profile.d/*.sh` が読み込まれるため、**全ユーザー共通の設定は `/etc/profile.d/` に置くのが基本**である。

## 設定ファイルの置き場所

| 置き場所 | 効く範囲 | 用途・注意 |
|---|---|---|
| `/etc/profile.d/*.sh` | 全ユーザー | プロンプト、エイリアス、履歴設定、環境変数。**基本はここ** |
| `/etc/bashrc` | 全ユーザー | OS 標準のファイル。パッケージ更新で置き換わる可能性があるため直接編集せず、`profile.d` で上書きする |
| `/home/<user>/.bashrc` | 特定ユーザー | ユーザー個別の設定。root で書いた後に `chown` する（cfn-init なら `owner` を指定） |
| `/etc/skel/.bashrc` 等 | 今後作成されるユーザー | `useradd` 時にホームディレクトリへコピーされる初期ファイル |

- `/etc/profile.d/` 内のファイルは**名前順**に読み込まれる。後から読まれた設定が優先されるため、`zz-prompt.sh` のように末尾に来る名前にしておくと他の設定に上書きされにくい。
- `/etc/profile.d/` のファイルは実行権限がなくても読み込まれる（`source` されるため）。パーミッションは `0644` でよい。

### /etc/skel が ec2-user に効かない理由

ec2-user（Ubuntu では ubuntu）は、UserData のスクリプトが実行される**前の段階**で cloud-init によって作成される。その時点で `/etc/skel` からホームディレクトリへのコピーは済んでいるため、UserData で `/etc/skel` を変更しても ec2-user には反映されない。`/etc/skel` の変更は、UserData 内でその後に作成するユーザー（アプリ用ユーザーなど）にだけ効く。

## 実装例

### UserData で配置する

```bash
#!/bin/bash
set -euo pipefail

cat > /etc/profile.d/zz-custom.sh <<'EOF'
# プロンプト: [環境名] ユーザー@ホスト:カレントディレクトリ
export PS1='\[\e[31m\][prod]\[\e[0m\] \u@\h:\w\$ '

# 履歴
export HISTTIMEFORMAT='%F %T '
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoredups

# エイリアス
alias ll='ls -alF'
alias la='ls -A'
EOF
chmod 644 /etc/profile.d/zz-custom.sh
```

ヒアドキュメントの区切りを `'EOF'` とクォートしておくと、`\u` や `$` が UserData の実行時に展開されず、そのまま書き込まれる。CloudFormation の `!Sub` の中に書く場合は、`${...}` 形式の記述が置換対象になる点にも注意する（上記の例には含まれていない）。

### cfn-init で配置する

```yaml
files:
  /etc/profile.d/zz-custom.sh:
    content: |
      export PS1='\[\e[31m\][prod]\[\e[0m\] \u@\h:\w\$ '
      export HISTTIMEFORMAT='%F %T '
      alias ll='ls -alF'
    mode: "000644"
    owner: root
    group: root
  /home/ec2-user/.vimrc:
    content: |
      set number
      syntax on
    mode: "000644"
    owner: ec2-user
    group: ec2-user
```

cfn-init + cfn-hup 構成にしておけば、テンプレートの `content` を変更してスタックを更新するだけで稼働中インスタンスにも反映される（[cfn-init + cfn-hup の例](./cfn-s3-userdata-provisioning.md#cfn-init--cfn-hup-の例)）。

## 環境ごとにプロンプトを切り替える

本番環境でプロンプトを赤くするなど、環境を取り違えないための表示は有効な対策である。環境名は次のいずれかで与える。

### CloudFormation パラメータで渡す

UserData の `!Sub` で環境名を埋め込む。最も単純。

```yaml
UserData:
  Fn::Base64: !Sub |
    #!/bin/bash
    echo 'export ENV_NAME=${EnvName}' > /etc/profile.d/00-env.sh
    cat >> /etc/profile.d/zz-custom.sh <<'EOF'
    case "$ENV_NAME" in
      prod) COLOR='31' ;;   # 赤
      stg)  COLOR='33' ;;   # 黄
      *)    COLOR='32' ;;   # 緑
    esac
    export PS1="\[\e[${!COLOR}m\][$ENV_NAME]\[\e[0m\] \u@\h:\w\\$ "
    EOF
```

`!Sub` の中ではシェルの `${COLOR}` を `${!COLOR}` とエスケープしている。CloudFormation が置換後に `${COLOR}` として出力する。

### インスタンスのタグから取得する

起動テンプレートの `MetadataOptions` で `InstanceMetadataTags: enabled` にすると、IMDS からインスタンスのタグを読める。`Env` タグの値を UserData で読み、プロンプトに反映できる。

```bash
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ENV_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Env)
echo "export ENV_NAME=$ENV_NAME" > /etc/profile.d/00-env.sh
```

タグのキーに `/` やスペースを含むものは IMDS で取得できない点に注意する。

## ホスト名

プロンプトの `\h` は、既定では `ip-10-0-1-23` のような VPC 内の DNS 名になり、どのサーバーか判別しにくい。

| 方法 | 記述 |
|---|---|
| UserData | `hostnamectl set-hostname web-prod-01` |
| `#cloud-config` | `hostname: web-prod-01` と `preserve_hostname: false`（`fqdn:` も指定可） |

- ホスト名を変更しても、VPC の DNS（`ip-10-0-1-23.ap-northeast-1.compute.internal`）は変わらない。名前解決が必要なら Route 53 のプライベートホストゾーン等を別途用意する。
- ホスト名は変えず、プロンプトにだけ識別名を表示する方法もある（`PS1` に `$ENV_NAME` や `Name` タグの値を埋め込む）。

## Session Manager で接続する場合

SSM Session Manager で接続すると、既定では `ssm-user` として `sh` が起動する。bash のログインシェルではないため、`/etc/profile.d/` の設定もプロンプトも効かない。Session Manager の設定（Session Manager preferences）で次のいずれかを行う。

| 設定 | 内容 |
|---|---|
| シェルプロファイル（Linux shell profile） | `exec bash -l`、または `exec sudo su - ec2-user` などを指定する。接続時に bash のログインシェルが起動する |
| Run As サポート | 接続ユーザーを `ssm-user` ではなく指定の OS ユーザー（ec2-user など）にする。IAM プリンシパルのタグ `SSMSessionRunAs` でユーザーごとに指定することもできる |

この設定はインスタンス側ではなく **アカウント・リージョン単位の Session Manager の設定**（SSM ドキュメント `SSM-SessionManagerRunShell`）であり、UserData では設定しない。CloudFormation で管理する場合は `AWS::SSM::Document`（`SessionManagerRunShell` 型）で定義する。

## 同じ方法でできる他のカスタマイズ

いずれもファイル配置またはコマンド実行なので、UserData / cfn-init で同様に設定できる。

| 項目 | 方法 |
|---|---|
| タイムゾーン | `timedatectl set-timezone Asia/Tokyo`、または `#cloud-config` の `timezone: Asia/Tokyo` |
| ロケール | `localectl set-locale LANG=ja_JP.UTF-8`（言語パックが必要な場合は `dnf install -y glibc-langpack-ja`） |
| ログイン時メッセージ | `/etc/motd`。Amazon Linux 2023 は `update-motd` の仕組みで生成しているため、直接編集ではなく `/etc/update-motd.d/` へのスクリプト追加などで行う |
| ユーザー設定ファイル | `.vimrc`、`.inputrc`、`.gitconfig`、`.tmux.conf` 等をホームディレクトリに配置し、所有者を合わせる |
| sudo 権限 | `/etc/sudoers.d/` にファイルを置き、`visudo -cf` で検証（[実行権限の補足](./userdata-cfn-init-privileges.md#sudo-権限の付与)） |
| SSH 設定 | `/etc/ssh/sshd_config.d/*.conf` にファイルを置き、`sshd -t` で検証してから `systemctl reload sshd` |

## 反映と更新

- 設定は**次回ログインから**有効になる。既存セッションで試すには `source /etc/profile.d/zz-custom.sh` を実行する。
- UserData は初回起動時にしか実行されないため、稼働中インスタンスの設定変更は次のいずれかで行う（[更新戦略](./cfn-s3-userdata-provisioning.md#更新戦略)）。
  - cfn-init + cfn-hup でテンプレートの変更を自動反映する
  - SSM Run Command / State Manager でファイルを配置し直す
  - インスタンスを置換する
- 台数が多く、設定がほぼ固定なら、カスタム AMI に焼き込むのが最も簡単である。

## 参考

- [Bash Reference Manual: Bash Startup Files](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html)
- [Controlling Bash prompt: PROMPTING](https://www.gnu.org/software/bash/manual/html_node/Controlling-the-Prompt.html)
- [Access instance tags in instance metadata](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/work-with-tags-in-IMDS.html)
- [Change the hostname of your Amazon Linux instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-hostname.html)
- [Session Manager: Configure shell profiles](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-shell-config.html)
- [Session Manager: Turn on Run As support](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html)
- [cloud-init documentation](https://cloudinit.readthedocs.io/)
