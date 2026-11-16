# 構成の提案: 海外からの確認の拠点（AWS の別のリージョンの AL2023 のインスタンス）

> 位置付け: 遮断を有効にした後に「海外からつながらない」ことを確かめるための接続元の構成（拠点はまだ作っていない）。接続元は AWS の別のリージョンでよく、確認は作業者が拠点で手で行う、と決まった（2026-10-29）。
>
> 関連: [手順](./steps.md)、[iptables ＋ ipset の仕組みと確認](./iptables-ipset.md)
>
> 定義: [EC2 Image Builder の定義（拠点の AMI）](./outside-probe/image-builder/README.md)、[Docker の定義（手元での再現）](./outside-probe/docker/README.md)、確認の処理 [`port-guard-probe`](./outside-probe/port-guard-probe)

## 結論

| 項目 | 提案 |
|---|---|
| 置き場所 | **米国のリージョン（例: us-west-2）** の、既定の VPC の公開のサブネット |
| インスタンス | **Amazon Linux 2023**、`t4g.nano`（arm64。この用途には十分で、いちばん安い） |
| 入り方 | **SSM だけ**（Session Manager・Run Command）。受信の口は開けない。SSH の鍵は作らない |
| 確かめる道具 | AL2023 に最初から入っている `python3`・`curl` に、`nmap-ncat`（`nc`）・`openssl` を足す。確認の処理は `port-guard-probe`（道具の `enable` と同じ判定。下の「[port-guard-probe の使い方](#port-guard-probe-の使い方)」） |
| AMI | 2 通り。[EC2 Image Builder の定義](./outside-probe/image-builder/README.md) で作った AMI（道具と `port-guard-probe` が入っている）か、AWS の最新の AL2023 の AMI ＋ UserData での導入 |
| 作り方 | CloudFormation の 1 つのスタック（作業の期間だけ作り、終わったら消す）。AMI は Image Builder で別に作っておける |
| 確かめ方 | **作業者が手で行う**（道具の `enable` には組み込まない）。拠点で `port-guard-probe` を実行し、**遮断の前は届き、遮断の後は届かない**ことを確かめる（下の「確かめる流れ」） |

## なぜこの形か

| 点 | 理由 |
|---|---|
| 米国のリージョン | 日本の IP の範囲は APNIC の割り当ての統計から取る。米国のリージョンの IP は ARIN（北米）の割り当てで、日本の範囲に入らないことがはっきりしている（アジアのリージョンは APNIC の管理の範囲なので、念のため避ける）。実際の拠点の IP は、`install --check-outside <拠点の IP>` で集合に入っていないことを確かめる |
| AL2023 | SSM Agent・`python3`・`curl` が最初から入っている。今の対象（AL2）とは別の環境なので、新しい OS でよい |
| `t4g.nano` | 数本の TCP の接続を試すだけなので、メモリ 0.5 GB で足りる |
| SSM だけ | 受信の口を開けないので、拠点そのものが攻撃の入口にならない。SSH の鍵の管理も要らない |
| 公開のサブネット（パブリック IP） | 対象のインスタンスへ、インターネットの経路で、海外の IP からつなぐ必要がある。NAT ゲートウェイは費用が高いので使わない |

## 構成

```
us-west-2（例）
└ 既定の VPC の公開のサブネット
   └ 確認の拠点（AL2023、t4g.nano、パブリック IP あり）
        ├ セキュリティグループ: 受信なし。送信は TCP 80・443・22 だけ
        ├ インスタンスプロファイル: AmazonSSMManagedInstanceCore
        └ 道具と port-guard-probe: Image Builder の AMI に入っている（AWS の AL2023 の AMI を使うときは UserData で入れる）

作業者の PC
  └ port-guard-rollout（AWS CLI）
       ├ ap-northeast-1 など（対象のインスタンス）
       └ us-west-2（拠点）: aws ssm send-command --region us-west-2 で、拠点から対象につながるかを試す
```

| 部品 | 内容 |
|---|---|
| AMI | Image Builder で作った AMI（`ProbeAmiId`）。指定しなければ、AL2023 の最新（SSM の公開のパラメーター `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`）に UserData で道具を入れる |
| ルートボリューム | gp3、8 GB（既定） |
| セキュリティグループ | **受信の許可なし**。送信は TCP 443（SSM の窓口、dnf のリポジトリ、対象の 443 番）、TCP 80（対象の 80 番）、TCP 22（対象の 22 番。`--include-ssh` のときだけ要る） |
| IAM | インスタンスのロールに `AmazonSSMManagedInstanceCore` だけ |
| IMDS | IMDSv2 を必須にする |
| タグ | `Name=port-guard-outside-probe`、`Purpose=port-guard-rollout-outside-probe` |

## 確かめ方

### 判定の考え方

「届かない」だけでは、遮断が効いたのか、ほかの理由（セキュリティグループ、対象のサービスが止まっている）なのかを区別できない。そこで、**遮断の前と後の 2 回**試す。

| 遮断の前 | 遮断の後 | 判定 |
|---|---|---|
| 届く | 届かない（時間切れ） | **合格**（海外からの接続が遮断された） |
| 届く | 届く | **不合格**（遮断が効いていない。手で外すか、原因を調べる） |
| 届く | 拒否（接続の拒否が返る） | 要確認（port-guard は破棄なので拒否は返さない。ほかの仕組みが応答している） |
| 届かない | — | **判定できない**（遮断の前から止まっている。セキュリティグループなどを見直す。22 番はセキュリティグループで弾いていることが多いので、ここになりやすい） |

「届く」の基準は、作業者の PC からの確認と同じ（80: HTTP の応答、443: TLS の接続、22: SSH のサーバーの応答）。TCP の接続だけでは判定しない。

### 確かめる流れ（作業者が手で行う）

海外からの確認は、道具（`enable`）には組み込まず、**作業者が拠点で手で行う**（2026-10-29 に決定）。

| # | いつ | すること |
|---|---|---|
| 1 | `install` のとき | 拠点のパブリック IP を `--check-outside` に渡し、拠点の IP が日本の集合にも許可する IP の一覧にも入っていないことを確かめる |
| 2 | `enable` の**前** | 拠点で `port-guard-probe <対象のパブリック IP> 80:http 443:tls` を実行し、**届く**（`reachable`）ことを確かめる。届かなければ、遮断の後の結果で判定できないので、セキュリティグループなどを先に見直す |
| 3 | `enable` で 1 台を確定した**後** | 拠点で同じコマンドを実行し、**時間切れ**（`timeout`）になることを確かめる。届いてしまったら、遮断が効いていないので、[手で外す](./iptables-ipset.md#外す元に戻す)か原因を調べる |

拠点での実行は、Session Manager で入って実行するか、作業者の PC から Run Command で実行する（下の「port-guard-probe の使い方」）。

### port-guard-probe の使い方

```
port-guard-probe <対象の IP かホスト名> <ポート>:<確かめ方> [...] [--timeout 秒]
```

| 確かめ方 | 届いたとみなす条件 |
|---|---|
| `http` | HTTP の応答（`HTTP/...`）が返る |
| `tls` | TLS の接続（握手）が終わる（証明書は確かめない） |
| `ssh` | SSH のサーバーの最初の応答（`SSH-...`）を受け取る |
| `tcp` | TCP の接続ができる（弱い確認） |

| 結果 | 意味 |
|---|---|
| `reachable` | 届いて、相手が応答した |
| `timeout` | 時間切れ（途中で破棄された。**port-guard の遮断はこれになる**） |
| `refused` | 接続を拒否された（相手まで届いたが、待ち受けていない、または拒否の応答） |
| `no-response` | TCP の接続はできたが、相手が決まった応答をしなかった |
| `error` | そのほか（名前を引けない、経路がない、など） |

人が読める行と、道具が読む `PG <キー>=<値>` の行（例 `PG probe_443=timeout`）を出す。終了コードは、すべて `reachable` なら 0、届かないものがあれば 1、使い方の誤りは 2。

### 手で確かめるとき

```bash
# 作業者の PC から、拠点に入る
aws ssm start-session --region us-west-2 --target <拠点のインスタンスの ID>

# 拠点の中で
port-guard-probe <対象のパブリック IP> 80:http 443:tls      # 遮断の前は reachable、後は timeout
port-guard-probe <対象のパブリック IP> 22:ssh 80:http 443:tls   # 22 番も対象にしたとき（install --include-ssh）
curl -s https://checkip.amazonaws.com                         # 拠点のパブリック IP（--check-outside に使う）

# Run Command で、拠点に入らずに試す
aws ssm send-command --region us-west-2 --instance-ids <拠点のインスタンスの ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["port-guard-probe <対象のパブリック IP> 80:http 443:tls"]'
```

## CloudFormation のテンプレート（案）

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: Outside probe for port-guard-rollout (Amazon Linux 2023, SSM only)

Parameters:
  VpcId:
    Type: AWS::EC2::VPC::Id
  SubnetId:
    Type: AWS::EC2::Subnet::Id
    Description: パブリック IP が付く公開のサブネット（既定の VPC のもの）
  ImageId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64
  ProbeAmiId:
    Type: String
    Default: ""
    Description: Image Builder で作った拠点の AMI の ID（空なら ImageId の AL2023 に UserData で道具を入れる）
  InstanceType:
    Type: String
    Default: t4g.nano

Conditions:
  UseProbeAmi:
    Fn::Not:
      - Fn::Equals:
          - Ref: ProbeAmiId
          - ""

Resources:
  SecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: port-guard outside probe (no inbound)
      VpcId:
        Ref: VpcId
      SecurityGroupEgress:
        - { IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 0.0.0.0/0 }
        - { IpProtocol: tcp, FromPort: 80, ToPort: 80, CidrIp: 0.0.0.0/0 }
        - { IpProtocol: tcp, FromPort: 22, ToPort: 22, CidrIp: 0.0.0.0/0 }

  Role:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: ec2.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - Fn::Sub: arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - Ref: Role

  Instance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId:
        Fn::If:
          - UseProbeAmi
          - Ref: ProbeAmiId
          - Ref: ImageId
      InstanceType:
        Ref: InstanceType
      IamInstanceProfile:
        Ref: InstanceProfile
      MetadataOptions:
        HttpTokens: required
      NetworkInterfaces:
        - DeviceIndex: "0"
          SubnetId:
            Ref: SubnetId
          AssociatePublicIpAddress: true
          GroupSet:
            - Ref: SecurityGroup
      # Image Builder の AMI を使わないときだけ、起動時に道具を入れる。
      # port-guard-probe も使うなら、../outside-probe/port-guard-probe の中身をここに足すか、Image Builder の AMI を使う
      UserData:
        Fn::If:
          - UseProbeAmi
          - Ref: AWS::NoValue
          - Fn::Base64: |
              #!/bin/bash
              dnf install -y nmap-ncat openssl
      Tags:
        - { Key: Name, Value: port-guard-outside-probe }
        - { Key: Purpose, Value: port-guard-rollout-outside-probe }

Outputs:
  InstanceId:
    Value:
      Ref: Instance
  PublicIp:
    Value:
      Fn::GetAtt: [Instance, PublicIp]
```

```bash
# 作る（us-west-2 の既定の VPC の公開のサブネットを指定する。Image Builder の AMI を使うなら ProbeAmiId も）
aws cloudformation deploy --region us-west-2 --stack-name port-guard-outside-probe \
  --template-file outside-probe.yml --capabilities CAPABILITY_IAM \
  --parameter-overrides VpcId=<VPC の ID> SubnetId=<サブネットの ID> ProbeAmiId=<拠点の AMI の ID>

# 拠点のインスタンスの ID とパブリック IP
aws cloudformation describe-stacks --region us-west-2 --stack-name port-guard-outside-probe \
  --query 'Stacks[0].Outputs' --output table

# SSM に登録されたか（Online）
aws ssm describe-instance-information --region us-west-2 \
  --filters "Key=InstanceIds,Values=<拠点のインスタンスの ID>" --query 'InstanceInformationList[].PingStatus'

# 作業が終わったら消す
aws cloudformation delete-stack --region us-west-2 --stack-name port-guard-outside-probe
```

## 費用（目安）

| 項目 | 目安 |
|---|---|
| `t4g.nano`（us-west-2） | 1 時間あたり 0.0042 ドル前後 |
| パブリック IPv4 | 1 時間あたり 0.005 ドル |
| EBS（gp3、8 GB） | 1 か月 0.64 ドル前後 |
| 合計 | 動かしっぱなしで 1 か月 7〜8 ドル前後。作業の期間だけ作って消せば、ほぼかからない |

料金は変わることがあるので、使う前に AWS の料金のページで確かめる。

## 作業者の権限（追加で要るもの）

| 対象 | 操作 |
|---|---|
| 拠点を作る・消す | `cloudformation:*`（このスタック）、`ec2:*`（インスタンス・セキュリティグループ）、`iam:CreateRole`・`iam:PassRole` など（このロール）、`ssm:GetParameters`（AMI のパラメーター） |
| 拠点で確かめる | 拠点のリージョンでの `ssm:SendCommand`（`AWS-RunShellScript`。拠点のインスタンスだけに絞る）、`ssm:GetCommandInvocation`、`ssm:DescribeInstanceInformation` |

## 決めること

| # | 論点 | 提案 |
|---|---|---|
| P1 | リージョン | us-west-2（ほかの米国のリージョンでもよい） |
| P2 | 置いておく期間 | 作業の期間だけ作り、終わったら消す |
| P3 | 道具への組み込み | **決定**: 組み込まない。作業者が拠点で手で確かめる |
| P4 | テンプレートの置き場所 | `port-guard-rollout/outside-probe.yml` として置く |
