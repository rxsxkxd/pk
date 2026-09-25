# SSM Session Manager による EC2 運用

> スコープ: AWS Systems Manager Session Manager で EC2 インスタンスに接続・操作する運用について、できることと、そのために必要な構成・設定
>
> スコープ外: オンプレミスサーバー（ハイブリッドアクティベーション）、Patch Manager 等 Session Manager 以外の Systems Manager 機能の詳細
>
> 関連: [EC2 へのファイル配備](./cfn-s3-userdata-provisioning.md) / [実行権限の補足](./userdata-cfn-init-privileges.md) / [シェル環境カスタマイズの補足](./shell-environment-customization.md) / [サンプル: nginx + Passenger + Rails](./samples/nginx-passenger-rails/README.md)

## 結論

Session Manager を使うと、**SSH のポート（22 番）を開けず、キーペアも配らずに**、IAM で認可されたユーザーだけがインスタンスのシェルに接続できる。操作ログを S3 / CloudWatch Logs に残せ、ポートフォワードで RDS などへの踏み台としても使える。EC2 インスタンスに対する Session Manager の利用自体に追加料金はかからない（ログの保存先や VPC エンドポイントの料金は別途かかる）。

利用には次の 4 つが揃っている必要がある。

| # | 必要なもの | 内容 |
|---|---|---|
| 1 | インスタンス側: SSM Agent | Amazon Linux 2 / 2023、Ubuntu（snap）、Windows の AWS 提供 AMI には導入済み |
| 2 | インスタンス側: IAM 権限 | インスタンスプロファイルに `AmazonSSMManagedInstanceCore`（またはアカウント単位の Default Host Management Configuration） |
| 3 | ネットワーク | インスタンスから Systems Manager のエンドポイントへのアウトバウンド HTTPS（443）。**インバウンドは不要** |
| 4 | 利用者側 | `ssm:StartSession` 等の IAM 権限。CLI から使う場合は AWS CLI と Session Manager プラグイン |

## できること

| 機能 | 概要 | 使う SSM ドキュメント | 操作ログ |
|---|---|---|---|
| シェル接続 | Linux は `sh` / bash、Windows は PowerShell の対話セッション | `SSM-SessionManagerRunShell`（既定） | 記録できる |
| ポートフォワード（インスタンス上のポート） | ローカルのポートをインスタンス上のポートに転送（例: アプリの管理画面、Windows の RDP） | `AWS-StartPortForwardingSession` | 記録できない |
| ポートフォワード（リモートホスト） | インスタンスを踏み台にして、VPC 内の別ホスト（RDS、ElastiCache、内部 ALB 等）に転送 | `AWS-StartPortForwardingSessionToRemoteHost` | 記録できない |
| SSH / SCP のトンネル | Session Manager の上で SSH を通す。`scp` / `rsync` / SSH 前提のツール（Ansible 等）が使える | `AWS-StartSSHSession` | 記録できない |
| 特定コマンドだけを許可 | 任意のシェルではなく、決められたコマンド（ログ閲覧など）だけを実行させる | `AWS-StartInteractiveCommand` またはカスタムの Session ドキュメント | 記録できる |
| 実行ユーザーの指定（Run As） | `ssm-user` ではなく、指定した OS ユーザーで接続する（Linux） | 設定で有効化 | — |
| ブラウザからの接続 | EC2 コンソールの「接続」や Systems Manager コンソールから、CLI なしで接続 | — | 記録できる |
| 監査 | セッションの開始・終了を CloudTrail に記録。セッション中の入出力を S3 / CloudWatch Logs に保存 | — | — |
| タイムアウト | 無操作時の切断（1〜60 分、既定 20 分）と、セッションの最大時間を設定 | — | — |

補足:

- ポートフォワードと SSH セッションは通信の中身が暗号化されたまま中継されるため、**セッション中の操作内容は記録されない**（開始・終了は CloudTrail に残る）。操作ログを必須とする環境では、これらのドキュメントの利用を IAM で禁止する。
- 1 回だけのコマンド実行や、複数台への一括実行は Session Manager ではなく **Run Command** の役割である（[関連機能との役割分担](#関連機能との役割分担)）。

## 構成・設定

### 1. インスタンス側: SSM Agent

| OS / AMI | SSM Agent | 状態確認 |
|---|---|---|
| Amazon Linux 2023 / 2 | 導入済み | `systemctl status amazon-ssm-agent` |
| Ubuntu（AWS 提供 AMI） | snap で導入済み | `snap services amazon-ssm-agent` |
| Windows（AWS 提供 AMI） | 導入済み | `Get-Service AmazonSSMAgent` |
| 独自 AMI / その他の OS | 手動で導入が必要 | — |

- エージェントは自動更新されないため、State Manager の関連付け（`AWS-UpdateSSMAgent`）で定期的に更新するか、AMI の更新で追従する。Session Manager の新しい機能には、新しいバージョンのエージェントが必要なものがある。
- Linux では、初回のセッション開始時にエージェントが OS ユーザー `ssm-user` を作成し、**`/etc/sudoers.d/ssm-agent-users` でパスワードなしの sudo を付与する**。sudo を使わせたくない場合は、このファイルを変更するか、Run As で権限の低いユーザーに接続させる。

### 2. インスタンス側: IAM 権限

次のいずれかでインスタンスに権限を与える。

| 方式 | 内容 | 使いどころ |
|---|---|---|
| **インスタンスプロファイル** | インスタンスのロールに AWS マネージドポリシー `AmazonSSMManagedInstanceCore` を付与 | 基本はこれ。他の権限（S3 読み取り等）と同じロールにまとめられる |
| Default Host Management Configuration（DHMC） | アカウント・リージョン単位で有効化すると、インスタンスプロファイルがなくても Systems Manager の管理対象になる | インスタンスプロファイルを付け忘れたインスタンスも含めて一律に管理したい場合。**IMDSv2 が必須**、エージェントのバージョン要件あり |

後述のログ保存や KMS 暗号化を使う場合は、インスタンスロールに追加の権限が必要になる（[ログと暗号化](#5-操作ログと暗号化)）。

ロールを後からアタッチした場合、エージェントが認識するまで数分かかることがある。すぐに反映させたい場合はエージェントを再起動する。

### 3. ネットワーク

Session Manager はインスタンスからの**アウトバウンド接続**だけで動作する。セキュリティグループにインバウンドのルールは不要で、SSH（22 番）も開ける必要がない。パブリック IP も不要である。

| サブネット | 必要な構成 |
|---|---|
| パブリックサブネット / NAT ゲートウェイあり | インスタンスのセキュリティグループでアウトバウンド 443 を許可（既定で全許可） |
| 外向き経路なし（完全プライベート） | 次のインターフェイス VPC エンドポイントを作成（プライベート DNS を有効化） |

| VPC エンドポイント | 用途 | 要否 |
|---|---|---|
| `com.amazonaws.<region>.ssm` | Systems Manager API | 必須 |
| `com.amazonaws.<region>.ssmmessages` | Session Manager のデータチャネル | 必須 |
| `com.amazonaws.<region>.ec2messages` | Run Command 等のメッセージ | 新しいエージェントでは不要な場合もあるが、作っておくのが無難 |
| `com.amazonaws.<region>.logs` | セッションログを CloudWatch Logs に送る場合 | 任意 |
| `com.amazonaws.<region>.kms` | セッションを KMS で暗号化する場合 | 任意 |
| S3 ゲートウェイエンドポイント | セッションログを S3 に送る場合 | 任意 |

エンドポイントに付けるセキュリティグループでは、VPC（またはインスタンスのセキュリティグループ）からのインバウンド 443 を許可する。インターフェイスエンドポイントは AZ ごと・時間単位で課金されるため、複数の VPC がある場合は共有 VPC に集約する構成も検討する。

### 4. 利用者側: IAM 権限とクライアント

#### IAM ポリシー

接続できるインスタンスと、使える SSM ドキュメント（シェル / ポートフォワード / SSH）を IAM で絞る。例: `Env=stg` タグの付いたインスタンスにだけシェル接続とリモートホストへのポートフォワードを許可する。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartSessionOnTaggedInstances",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": { "ssm:resourceTag/Env": "stg" },
        "BoolIfExists": { "ssm:SessionDocumentAccessCheck": "true" }
      }
    },
    {
      "Sid": "AllowedSessionDocuments",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell",
        "arn:aws:ssm:*::document/AWS-StartPortForwardingSessionToRemoteHost"
      ]
    },
    {
      "Sid": "ManageOwnSessions",
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:*:*:session/${aws:userid}-*"
    },
    {
      "Sid": "ConsoleListing",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ssm:DescribeInstanceInformation",
        "ssm:DescribeSessions",
        "ssm:GetConnectionStatus"
      ],
      "Resource": "*"
    }
  ]
}
```

- `ssm:StartSession` は**インスタンスと SSM ドキュメントの両方**に対して許可が必要。ドキュメントの許可を省くと、既定のシェル接続しかできない。`ssm:SessionDocumentAccessCheck` を `true` にすると、既定ドキュメント（`SSM-SessionManagerRunShell`）を使う場合もドキュメントに対する許可が確認される。
- `ssm:TerminateSession` は自分のセッションに限定する。セッション ID は利用者の識別子で始まる（IAM ユーザーならユーザー名、フェデレーションやロール経由ならロールセッション名等）。利用形態に合わせて `${aws:username}` / `${aws:userid}` を選ぶ。
- 操作ログを必須とするなら、`AWS-StartSSHSession` / `AWS-StartPortForwardingSession*` を許可しない。
- 本番環境へのシェル接続は、別のロール（スイッチロールや IAM Identity Center の権限セット）に分けて付与すると、誰がいつ本番に入ったかを追いやすい。

#### クライアント

| 接続方法 | 必要なもの |
|---|---|
| ブラウザ（EC2 コンソールの「接続」→「セッションマネージャー」、Systems Manager コンソール） | なし |
| AWS CLI（`aws ssm start-session`） | AWS CLI と **Session Manager プラグイン**（`session-manager-plugin`）。macOS は `brew install --cask session-manager-plugin` 等 |

### 5. 操作ログと暗号化

Session Manager の設定（Session preferences）で、セッションの入出力を保存・暗号化できる。設定はインスタンスではなく**アカウント・リージョン単位**で、実体は `SSM-SessionManagerRunShell` という Session タイプの SSM ドキュメントである。

| 設定項目（ドキュメントの `inputs`） | 内容 |
|---|---|
| `s3BucketName` / `s3KeyPrefix` / `s3EncryptionEnabled` | セッション終了時にログを S3 に保存 |
| `cloudWatchLogGroupName` / `cloudWatchEncryptionEnabled` / `cloudWatchStreamingEnabled` | CloudWatch Logs に保存。ストリーミングを有効にするとセッション中にリアルタイムで送られる |
| `kmsKeyId` | セッションのデータ通信を KMS キーで追加暗号化（通信自体は既定で TLS 1.2 以上） |
| `idleSessionTimeout` | 無操作時に切断するまでの分数（1〜60、既定 20） |
| `maxSessionDuration` | セッションの最大時間（分） |
| `runAsEnabled` / `runAsDefaultUser` | Run As の有効化と既定の OS ユーザー（Linux） |
| `shellProfile.linux` / `shellProfile.windows` | セッション開始時に実行するコマンド（例: `exec bash -l`）。[シェル環境カスタマイズの補足](./shell-environment-customization.md#session-manager-で接続する場合)を参照 |

ログと暗号化に必要な権限:

| 誰に | 権限 | 条件 |
|---|---|---|
| インスタンスロール | `s3:PutObject`、`s3:GetEncryptionConfiguration`（保存先バケット） | S3 に保存する場合 |
| インスタンスロール | `logs:CreateLogStream`、`logs:PutLogEvents`、`logs:DescribeLogGroups`、`logs:DescribeLogStreams` | CloudWatch Logs に保存する場合 |
| インスタンスロール | `kms:Decrypt`（`kmsKeyId` のキー） | KMS 暗号化を有効にする場合 |
| 利用者 | `kms:GenerateDataKey`（同じキー） | KMS 暗号化を有効にする場合 |

注意点:

- ログは**インスタンスから**送られる。インスタンスから S3 / CloudWatch Logs に到達できない、または権限がない場合、設定によってはセッションを開始できなくなる。
- ログにはセッション中の入出力がすべて含まれる。画面に表示したパスワードや秘密鍵も記録されるため、保存先のアクセス権を絞り、保持期間を決める。
- 前述のとおり、ポートフォワードと SSH セッションの中身は記録されない。

### 6. Run As（実行ユーザーの指定）

既定では全員が `ssm-user`（sudo 可）で接続するため、OS 上では誰が操作したか区別できない（CloudTrail とセッションログでは区別できる）。Run As を使うと、接続ユーザーを OS ユーザーに対応させられる。

1. 設定で `runAsEnabled: true` にし、`runAsDefaultUser` を指定する。
2. 利用者ごとに変えたい場合は、IAM ユーザーまたはロールにタグ `SSMSessionRunAs` を付け、値に OS ユーザー名を設定する（タグが既定ユーザーより優先される）。
3. 指定する OS ユーザーは、インスタンス上に事前に作成しておく（UserData 等で作成。[実行権限の補足](./userdata-cfn-init-privileges.md)）。存在しない場合は接続に失敗する。

## CloudFormation での構成例

### VPC エンドポイント（完全プライベートなサブネット向け）

```yaml
  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: SSM interface endpoints
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref VpcCidr

  SsmEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VpcId
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ssm
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: !Ref PrivateSubnetIds
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  SsmMessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VpcId
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ssmmessages
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: !Ref PrivateSubnetIds
      SecurityGroupIds: [!Ref EndpointSecurityGroup]

  Ec2MessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VpcId
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ec2messages
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: !Ref PrivateSubnetIds
      SecurityGroupIds: [!Ref EndpointSecurityGroup]
```

### セッションの設定（ログ・タイムアウト・シェル）

```yaml
  SessionLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /ssm/session-manager
      RetentionInDays: 365

  SessionManagerPreferences:
    Type: AWS::SSM::Document
    Properties:
      Name: SSM-SessionManagerRunShell
      DocumentType: Session
      Content:
        schemaVersion: "1.0"
        description: Session Manager preferences
        sessionType: Standard_Stream
        inputs:
          cloudWatchLogGroupName: !Ref SessionLogGroup
          cloudWatchEncryptionEnabled: false
          cloudWatchStreamingEnabled: true
          s3BucketName: ""
          s3EncryptionEnabled: true
          kmsKeyId: ""
          idleSessionTimeout: "20"
          maxSessionDuration: "480"
          runAsEnabled: false
          runAsDefaultUser: ""
          shellProfile:
            linux: exec bash -l
            windows: ""
```

- `SSM-SessionManagerRunShell` はアカウント・リージョンに 1 つだけ存在する。**誰かがコンソールで Session Manager の設定画面を開いて保存すると、この名前のドキュメントが自動作成され、CloudFormation での作成が名前の重複で失敗する**。既に存在する場合は、コンソールまたは `aws ssm update-document` で管理するか、既存のドキュメントを削除してから CloudFormation で作成する。
- 複数アカウントで統一したい場合は、CloudFormation StackSets で配布する。
- `cloudWatchEncryptionEnabled: true` にする場合は、ロググループ側を KMS キーで暗号化しておく必要がある。

インスタンスロールへの追加（CloudWatch Logs に保存する場合）:

```yaml
      Policies:
        - PolicyName: session-manager-logging
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                  - logs:DescribeLogStreams
                Resource: !Sub ${SessionLogGroup.Arn}:*
              - Effect: Allow
                Action: logs:DescribeLogGroups
                Resource: "*"
```

## 利用例

### シェル接続

```bash
aws ssm start-session --target i-0123456789abcdef0
```

Linux では `sh` が起動する（シェルプロファイル未設定の場合）。`bash -l` や `sudo su - ec2-user` で切り替える。

### RDS へのポートフォワード（踏み台として使う）

```bash
aws ssm start-session \
  --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["mydb.xxxxxxxx.ap-northeast-1.rds.amazonaws.com"],"portNumber":["3306"],"localPortNumber":["13306"]}'

# 別のターミナルから
mysql -h 127.0.0.1 -P 13306 -u admin -p
```

- 踏み台となるインスタンスから RDS に到達できる必要がある（RDS のセキュリティグループで、インスタンスのセキュリティグループからの 3306 を許可）。
- 踏み台専用に小さなインスタンスを置き、シェル接続を禁止してポートフォワードだけを許可する構成もできる。

### インスタンス上のポートへのフォワード

```bash
aws ssm start-session \
  --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["80"],"localPortNumber":["8080"]}'
# ブラウザで http://localhost:8080/
```

Windows インスタンスの RDP（3389）も同じ方法で接続できる。

### SSH / SCP を Session Manager 経由で使う

`~/.ssh/config`:

```
Host i-* mi-*
    ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

```bash
ssh ec2-user@i-0123456789abcdef0
scp ./file.txt ec2-user@i-0123456789abcdef0:/tmp/
```

- セキュリティグループで 22 番を開ける必要はないが、**SSH の認証（公開鍵）は通常どおり必要**。キーペアを配りたくない場合は、接続直前に `aws ec2-instance-connect send-ssh-public-key` で一時的な公開鍵（60 秒有効）を送り込む方法がある。
- セッションの中身は記録されない。

### ファイル転送

| 方法 | 内容 |
|---|---|
| S3 経由 | 手元から `aws s3 cp` でアップロードし、セッション内で `aws s3 cp` でダウンロード。インスタンスロールに対象プレフィックスの権限が必要。操作ログが残る |
| SCP（上記） | 手軽だが SSH の鍵と `AWS-StartSSHSession` の許可が必要。中身は記録されない |

## 関連機能との役割分担

| 機能 | 用途 | 例 |
|---|---|---|
| **Session Manager** | 人が対話的に操作する | 障害調査、ログ確認、一時的な作業、DB への接続 |
| Run Command | 決まったコマンドを 1 台〜多数に一括実行し、結果を記録 | 設定ファイルの再配置、サービス再起動、情報収集 |
| State Manager | 状態を定期的に適用し続ける | SSM Agent の更新、設定のドリフト修正 |
| Patch Manager | OS パッチの適用 | 定期パッチ |
| EC2 Instance Connect Endpoint | SSH / RDP をプライベートサブネットのインスタンスへ直接つなぐ（SSM Agent 不要） | SSM Agent を入れられない AMI |

定型化できる作業は Session Manager で手作業にせず、Run Command のドキュメントにして、手順と実行履歴を残す。

## トラブルシューティング

| 症状 | 確認箇所・原因 |
|---|---|
| Fleet Manager（マネージドノード）にインスタンスが表示されない | SSM Agent が停止している、インスタンスロールに `AmazonSSMManagedInstanceCore` がない、エンドポイントへの経路がない（NAT / VPC エンドポイント、エンドポイントのセキュリティグループ、プライベート DNS）、IMDS に到達できない |
| `TargetNotConnected` | 上と同じ。インスタンスが停止中の場合も発生する |
| `SessionManagerPlugin is not found` | 手元に Session Manager プラグインが入っていない |
| `AccessDeniedException`（StartSession） | インスタンスまたは SSM ドキュメントに対する `ssm:StartSession` の許可がない。タグ条件の不一致 |
| セッションがすぐ切断される / 開始できない | ログの保存先（S3 / CloudWatch Logs）に書き込めない、KMS キーの権限不足 |
| `sh` が起動し、bash の設定が効かない | シェルプロファイル未設定。`exec bash -l` を設定する |
| Run As で接続できない | 指定した OS ユーザーがインスタンス上に存在しない |
| インスタンス上のエージェントのログ | Linux: `/var/log/amazon/ssm/amazon-ssm-agent.log`、`errors.log`（Ubuntu の snap 版も同じパス） |

## チェックリスト

- [ ] インスタンスロールに `AmazonSSMManagedInstanceCore` を付与した（または DHMC を有効化した）
- [ ] SSM Agent が導入済みで、更新方法（State Manager / AMI 更新）を決めた
- [ ] プライベートサブネットの場合、`ssm` / `ssmmessages` / `ec2messages` の VPC エンドポイントを作成した
- [ ] セキュリティグループから SSH（22 番）のインバウンドを削除した
- [ ] 利用者の IAM ポリシーで、接続できるインスタンス（タグ）と SSM ドキュメントを限定した
- [ ] `ssm:TerminateSession` / `ssm:ResumeSession` を自分のセッションに限定した
- [ ] セッションログを S3 / CloudWatch Logs に保存し、保持期間とアクセス権を決めた
- [ ] 操作ログが必須なら、ポートフォワードと SSH のドキュメントを許可していない
- [ ] アイドルタイムアウトと最大セッション時間を設定した
- [ ] `ssm-user` の sudo 権限、または Run As の方針を決めた
- [ ] 利用者の端末に Session Manager プラグインを導入した

## 参考

- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Setting up Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started.html)
- [Create VPC endpoints for Systems Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html)
- [Default Host Management Configuration](https://docs.aws.amazon.com/systems-manager/latest/userguide/fleet-manager-default-host-management-configuration.html)
- [Control user session access to instances（IAM ポリシー例）](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started-restrict-access.html)
- [Session document schema](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-schema.html)
- [Logging session activity](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-logging.html)
- [Turn on Run As support for Linux and macOS managed nodes](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html)
- [Starting a session（ポートフォワード・SSH）](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html)
- [Install the Session Manager plugin for the AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
