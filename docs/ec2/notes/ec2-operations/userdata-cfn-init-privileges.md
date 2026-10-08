# 補足: UserData・cfn-init の実行権限（root / sudo）

> スコープ: CloudFormation で作成する EC2 インスタンス上で、UserData・cfn-init・cfn-hup・SSM Run Command がどの OS ユーザー権限で実行されるか、および一般ユーザーでの実行方法
>
> スコープ外: IAM ポリシーの詳細設計、OS のユーザー管理全般
>
> 関連: [EC2 へのファイル配備 — CloudFormation + S3 + UserData](./cfn-s3-userdata-provisioning.md) / [EC2 での Let's Encrypt 証明書発行・初期設定の自動化](./letsencrypt-automation.md)

## 結論

**可能である。UserData も cfn-init も最初から root 権限で実行されるため、`sudo` を付けなくても管理者権限が必要な操作（パッケージのインストール、`/etc` 以下の編集、サービスの起動など）をそのまま実行できる。**

| 実行手段 | 実行ユーザー（Linux） | `sudo` の要否 |
|---|---|---|
| UserData（シェルスクリプト） | root | 不要 |
| UserData（`#cloud-config` の `runcmd` / `write_files`） | root | 不要 |
| cfn-init（`packages` / `commands` / `services` / `files`） | root（UserData から呼ばれるため） | 不要 |
| cfn-hup のフック | root（`runas=` で変更可） | 不要 |
| SSM Run Command（`AWS-RunShellScript`） | root | 不要 |
| UserData（Windows / EC2Launch v2） | LocalSystem | — |

## UserData

### root で実行される

UserData は cloud-init が **root ユーザーとして**実行する。次のような操作は `sudo` なしで書いてよい。

```bash
#!/bin/bash
dnf install -y nginx
cp /tmp/app.conf /etc/nginx/conf.d/
systemctl enable --now nginx
```

`sudo` を付けても root が root として実行するだけでエラーにはならないが、不要である。ただし、古い RHEL / CentOS 系で `/etc/sudoers` に `Defaults requiretty` が設定されている場合は、端末（TTY）のない UserData から `sudo` を呼ぶと失敗する。Amazon Linux 2023 にはこの設定はない。

### 一般ユーザーとして実行する

アプリケーションのセットアップなど、一般ユーザーの権限で実行すべき処理は、root から権限を下げて実行する。

```bash
# 指定ユーザーで実行（環境変数は引き継がれる部分がある）
sudo -u ec2-user bash -c 'cd ~ && ./setup.sh'

# ログインシェル相当の環境（HOME、PATH、シェル設定）で実行
runuser -l ec2-user -c './setup.sh'
```

root で作成したファイルを一般ユーザーが使う場合は、`chown` で所有者を変更しておく。

```bash
mkdir -p /opt/myapp
chown -R ec2-user:ec2-user /opt/myapp
```

### 実行環境の違いに注意する

UserData の実行環境は対話ログインとは異なり、`HOME` や `PATH` などの環境変数が最小限の場合がある。

- `~` やホームディレクトリの設定ファイルを前提にするツールが意図どおり動かないことがある。
- `/usr/local/bin` などに置いたコマンドが見つからないことがある。

対策として、コマンドはフルパスで書くか、スクリプトの冒頭で必要な環境変数を設定する。

```bash
#!/bin/bash
set -euo pipefail
export HOME=/root
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
```

## cfn-init

cfn-init は UserData から呼び出されるため、cfn-init 自体とそこから実行される処理はすべて root 権限で動く。

| キー | 権限に関する挙動 |
|---|---|
| `packages` | root でインストールする |
| `files` | root で配置する。`owner` / `group` / `mode` で所有者とパーミッションを指定できる |
| `sources` | root で展開する |
| `users` / `groups` | root で OS ユーザー・グループを作成する |
| `commands` | root で実行する。**実行ユーザーを指定する項目はない** |
| `services` | root でサービスを有効化・起動する |

### 所有者を指定してファイルを配置する

```yaml
files:
  /opt/myapp/config.yml:
    content: |
      log_level: info
    mode: "000640"
    owner: ec2-user
    group: ec2-user
```

### commands を一般ユーザーで実行する

`commands` には実行ユーザーを指定する項目がないため、`command` の中で権限を下げる。

```yaml
commands:
  01_setup_app:
    command: runuser -l ec2-user -c '/opt/myapp/setup.sh'
    cwd: /opt/myapp
```

### cfn-hup

cfn-hup は root のサービスとして動作する。フック設定（`/etc/cfn/hooks.d/*.conf`）の `runas=` で、フックの `action` を実行するユーザーを指定できる。cfn-init を再実行するフックは root 権限が必要なので `runas=root` にする。

## 関連する実行手段

### SSM Run Command

Linux ではデフォルトで root として実行される。稼働中のインスタンスの更新作業も `sudo` なしで行える。一般ユーザーで実行したい場合は UserData と同様に `sudo -u` / `runuser` を使う。

### Windows

UserData（`<powershell>` / `<script>`）は EC2Launch v2 が LocalSystem 権限で実行する。

### sudo 権限の付与

UserData から他のユーザーに sudo 権限を付与することもできる。`/etc/sudoers` を直接編集せず、`/etc/sudoers.d/` にファイルを置き、構文を検証する。

```bash
cat > /etc/sudoers.d/90-deploy <<'EOF'
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
EOF
chmod 440 /etc/sudoers.d/90-deploy
visudo -cf /etc/sudoers.d/90-deploy
```

`ALL` をそのまま許可せず、必要なコマンドだけに限定する。Amazon Linux の `ec2-user` は初期状態でパスワードなしの sudo（全コマンド）が可能である。

## セキュリティ上の注意

### OS の root と AWS の権限は別物

OS 上で root であっても、AWS API に対してできることはインスタンスプロファイル（IAM ロール）の権限に限られる。例えば `aws s3 cp` が成功するかどうかは、OS のユーザーではなく IAM ロールで決まる。逆に、同じインスタンス上のどの OS ユーザーでも IMDS 経由でインスタンスプロファイルの認証情報を取得できるため、一般ユーザーで動くアプリも IAM ロールの権限を使える点に注意する。

### UserData を変更できる人は root でコードを実行できる

UserData、起動テンプレート、CloudFormation スタックを書き換えられる人は、インスタンス上で root としてコードを実行できるのと同じである。次のような IAM 権限は限られた人・パイプラインに絞る。

| 権限 | 理由 |
|---|---|
| `ec2:ModifyInstanceAttribute` | 既存インスタンスの UserData を変更できる |
| `ec2:CreateLaunchTemplateVersion` / `ec2:ModifyLaunchTemplate` | 起動テンプレートの UserData を変更できる |
| `ec2:RunInstances` + `iam:PassRole` | 任意の UserData とロールでインスタンスを起動できる |
| `cloudformation:UpdateStack` / `CreateChangeSet` | テンプレート経由で UserData や cfn-init のメタデータを変更できる |
| `ssm:SendCommand` | 稼働中のインスタンスで root としてコマンドを実行できる |

### UserData にシークレットを書かない

UserData は `DescribeInstanceAttribute` で読み取れ、インスタンス内からも IMDS で誰でも（一般ユーザーでも）取得できる。シークレットは Parameter Store（SecureString）や Secrets Manager から起動時に取得する。

## 参考

- [Run commands when you launch an EC2 instance with user data input](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [AWS::CloudFormation::Init](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-init.html)
- [cfn-hup](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-hup.html)
- [AWS Systems Manager Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html)
- [EC2Launch v2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2launch-v2.html)
