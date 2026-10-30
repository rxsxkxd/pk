# AWS CLI で各サービスの設定を一覧・取得するコマンド集

各サービスの「一覧取得（list / describe）」で対象を洗い出し、必要に応じて「詳細取得（get / describe / batch-get）」で設定の中身まで取る、という流れでまとめる。

- 実行に必要な権限: 読み取りだけなので、AWS 管理ポリシー `ReadOnlyAccess`（または `ViewOnlyAccess` + 個別の Get 権限）で足りる
- レスポンス例のIDやARNはダミー。項目は主要なものだけ残して省略している（`...`）

## 目次

| 分類 | サービス |
|---|---|
| 処理を動かす・データを持つ | [EC2](#ec2) / [ECS](#ecs) / [Fargate](#fargate) / [RDS](#rds) / [S3](#s3) |
| ネットワークの区画と通信の制御 | [VPC](#vpc) / [サブネット](#サブネット) / [セキュリティグループ](#セキュリティグループ) |
| サーバーを管理しない実行環境と、メッセージによる処理の切り離し | [Lambda](#lambda) / [API Gateway](#api-gateway) / [SNS](#sns) / [SQS](#sqs) |
| 入口での配信・負荷分散・攻撃の遮断 | [CloudFront](#cloudfront) / [ALB](#albelastic-load-balancing-v2) / [WAF](#wafwafv2) |
| インフラ全体をコードで構築する土台と、権限の管理 | [CloudFormation](#cloudformation) / [IAM](#iam) |
| ビルド・デプロイ・イメージ作成の自動化 | [CodeBuild](#codebuild) / [CodeDeploy](#codedeploy) / [CodePipeline](#codepipeline) / [EC2 Image Builder](#ec2-image-builder) |

## 共通の使い方

```bash
# 共通オプション
aws <service> <command> \
  --profile myprof \        # 認証情報のプロファイル
  --region ap-northeast-1 \ # リージョン（CloudFront / IAM はグローバル）
  --output json \           # json / table / text / yaml
  --query '<JMESPath>'      # 必要な項目だけ抜き出す

# 一覧の結果を詳細取得に流す基本形
for name in $(aws <service> list-xxx --query 'xxx[].Name' --output text); do
  aws <service> get-xxx --name "$name"
done
```

- ページングは CLI が自動で全件たどる。件数が多いときは `--page-size` で 1 回あたりの件数を減らせる
- `--output text` はタブ区切りで出るので、`for` に渡すとそのまま 1 件ずつ回せる
- 全リージョンを見るときは `aws ec2 describe-regions --query 'Regions[].RegionName' --output text` で回す

---

# 処理を動かす・データを持つ

## EC2

| 取得したいもの | コマンド |
|---|---|
| インスタンス | `aws ec2 describe-instances` |
| 起動テンプレート | `aws ec2 describe-launch-templates` / `describe-launch-template-versions` |
| EBS ボリューム | `aws ec2 describe-volumes` |
| AMI（自アカウント） | `aws ec2 describe-images --owners self` |
| キーペア | `aws ec2 describe-key-pairs` |
| Auto Scaling グループ | `aws autoscaling describe-auto-scaling-groups` |

### コマンド例

```bash
# インスタンス一覧（主要項目だけ）
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,Name:Tags[?Key==`Name`]|[0].Value,PrivateIp:PrivateIpAddress,Subnet:SubnetId,SGs:SecurityGroups[].GroupId}' \
  --output json

# 起動テンプレートの最新バージョンの中身
aws ec2 describe-launch-template-versions \
  --launch-template-id lt-0abc1234def567890 --versions '$Latest'
```

### レスポンス例

```json
[
  {
    "Id": "i-0123456789abcdef0",
    "Type": "t3.medium",
    "State": "running",
    "Name": "web-01",
    "PrivateIp": "10.0.1.15",
    "Subnet": "subnet-0aaa1111bbbb2222c",
    "SGs": ["sg-0123abcd4567ef890"]
  }
]
```

`--query` なしの場合（抜粋）:

```json
{
  "Reservations": [
    {
      "ReservationId": "r-0abc1234def567890",
      "OwnerId": "123456789012",
      "Instances": [
        {
          "InstanceId": "i-0123456789abcdef0",
          "ImageId": "ami-0a1b2c3d4e5f67890",
          "InstanceType": "t3.medium",
          "State": { "Code": 16, "Name": "running" },
          "VpcId": "vpc-0123456789abcdef0",
          "SubnetId": "subnet-0aaa1111bbbb2222c",
          "PrivateIpAddress": "10.0.1.15",
          "IamInstanceProfile": { "Arn": "arn:aws:iam::123456789012:instance-profile/web-role" },
          "SecurityGroups": [{ "GroupId": "sg-0123abcd4567ef890", "GroupName": "web-sg" }],
          "BlockDeviceMappings": [{ "DeviceName": "/dev/xvda", "Ebs": { "VolumeId": "vol-0abc...", "DeleteOnTermination": true } }],
          "MetadataOptions": { "HttpTokens": "required", "HttpEndpoint": "enabled" },
          "Tags": [{ "Key": "Name", "Value": "web-01" }]
        }
      ]
    }
  ]
}
```

## ECS

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| クラスター | `aws ecs list-clusters` | `aws ecs describe-clusters --clusters <arn...>` |
| サービス | `aws ecs list-services --cluster <c>` | `aws ecs describe-services --cluster <c> --services <arn...>`（1回10件まで） |
| タスク定義 | `aws ecs list-task-definition-families --status ACTIVE` / `list-task-definitions` | `aws ecs describe-task-definition --task-definition <family[:rev]>` |
| 実行中タスク | `aws ecs list-tasks --cluster <c>` | `aws ecs describe-tasks --cluster <c> --tasks <arn...>` |
| キャパシティプロバイダー | — | `aws ecs describe-capacity-providers` |

### コマンド例

```bash
# クラスター → サービスの設定をまとめて取る
for c in $(aws ecs list-clusters --query 'clusterArns[]' --output text); do
  aws ecs describe-clusters --clusters "$c" --include SETTINGS CONFIGURATIONS STATISTICS
  svcs=$(aws ecs list-services --cluster "$c" --query 'serviceArns[]' --output text)
  [ -n "$svcs" ] && aws ecs describe-services --cluster "$c" --services $svcs \
    --query 'services[].{name:serviceName,taskDef:taskDefinition,desired:desiredCount,running:runningCount,launchType:launchType,cp:capacityProviderStrategy,net:networkConfiguration.awsvpcConfiguration,lb:loadBalancers}'
done

# 有効なタスク定義ファミリーの最新リビジョン
for f in $(aws ecs list-task-definition-families --status ACTIVE --query 'families[]' --output text); do
  aws ecs describe-task-definition --task-definition "$f" --query 'taskDefinition'
done
```

### レスポンス例

`list-clusters`:

```json
{
  "clusterArns": [
    "arn:aws:ecs:ap-northeast-1:123456789012:cluster/app-prod"
  ]
}
```

`describe-services`（`--query` で抜粋）:

```json
[
  {
    "name": "api",
    "taskDef": "arn:aws:ecs:ap-northeast-1:123456789012:task-definition/api:42",
    "desired": 2,
    "running": 2,
    "launchType": "FARGATE",
    "cp": null,
    "net": {
      "subnets": ["subnet-0aaa1111bbbb2222c", "subnet-0ddd3333eeee4444f"],
      "securityGroups": ["sg-0api1111aaaa2222b"],
      "assignPublicIp": "DISABLED"
    },
    "lb": [
      {
        "targetGroupArn": "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/api-tg/0123456789abcdef",
        "containerName": "api",
        "containerPort": 8080
      }
    ]
  }
]
```

`describe-task-definition`（抜粋）:

```json
{
  "family": "api",
  "revision": 42,
  "taskRoleArn": "arn:aws:iam::123456789012:role/api-task-role",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "runtimePlatform": { "cpuArchitecture": "ARM64", "operatingSystemFamily": "LINUX" },
  "containerDefinitions": [
    {
      "name": "api",
      "image": "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/api:1.4.0",
      "portMappings": [{ "containerPort": 8080, "protocol": "tcp" }],
      "environment": [{ "name": "APP_ENV", "value": "production" }],
      "secrets": [{ "name": "DB_PASSWORD", "valueFrom": "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:db-pass-AbCdEf" }],
      "logConfiguration": { "logDriver": "awslogs", "options": { "awslogs-group": "/ecs/api", "awslogs-region": "ap-northeast-1", "awslogs-stream-prefix": "api" } }
    }
  ],
  "status": "ACTIVE"
}
```

## Fargate

Fargate は ECS（または EKS）の起動タイプなので、専用の API はない。ECS の API を Fargate 条件で絞り込んで取る。

| 取得したいもの | コマンド |
|---|---|
| Fargate で動くタスク | `aws ecs list-tasks --cluster <c> --launch-type FARGATE` → `describe-tasks` |
| Fargate で動くサービス | `aws ecs list-services --cluster <c> --launch-type FARGATE` → `describe-services` |
| クラスターの既定キャパシティプロバイダー（FARGATE / FARGATE_SPOT） | `aws ecs describe-clusters --clusters <c>` の `capacityProviders` / `defaultCapacityProviderStrategy` |
| Fargate 用のタスク定義 | `aws ecs list-task-definitions` → `describe-task-definition` で `requiresCompatibilities` に `FARGATE` |
| EKS の Fargate プロファイル | `aws eks list-fargate-profiles --cluster-name <c>` → `describe-fargate-profile` |

> 注意: キャパシティプロバイダー戦略（FARGATE / FARGATE_SPOT）で起動したサービスは `launchType` が空になり、`--launch-type FARGATE` の絞り込みに出てこない。`capacityProviderStrategy` も合わせて確認する。

### コマンド例

```bash
c=app-prod
tasks=$(aws ecs list-tasks --cluster "$c" --launch-type FARGATE --query 'taskArns[]' --output text)
aws ecs describe-tasks --cluster "$c" --tasks $tasks \
  --query 'tasks[].{task:taskArn,def:taskDefinitionArn,status:lastStatus,cp:capacityProviderName,platform:platformVersion,cpu:cpu,mem:memory,az:availabilityZone,eni:attachments[0].details[?name==`privateIPv4Address`].value|[0]}'

# サービスの起動方法（launchType と capacityProviderStrategy の両方）
aws ecs describe-services --cluster "$c" --services api \
  --query 'services[].{name:serviceName,launchType:launchType,cp:capacityProviderStrategy,platform:platformVersion}'
```

### レスポンス例

```json
[
  {
    "task": "arn:aws:ecs:ap-northeast-1:123456789012:task/app-prod/0123456789abcdef0123456789abcdef",
    "def": "arn:aws:ecs:ap-northeast-1:123456789012:task-definition/api:42",
    "status": "RUNNING",
    "cp": "FARGATE",
    "platform": "1.4.0",
    "cpu": "512",
    "mem": "1024",
    "az": "ap-northeast-1a",
    "eni": "10.0.11.23"
  }
]
```

```json
[
  {
    "name": "worker",
    "launchType": null,
    "cp": [
      { "capacityProvider": "FARGATE_SPOT", "weight": 3, "base": 0 },
      { "capacityProvider": "FARGATE", "weight": 1, "base": 1 }
    ],
    "platform": "LATEST"
  }
]
```

## RDS

| 取得したいもの | コマンド |
|---|---|
| DB インスタンス | `aws rds describe-db-instances` |
| Aurora クラスター | `aws rds describe-db-clusters` |
| パラメータグループ（インスタンス / クラスター） | `aws rds describe-db-parameter-groups` / `describe-db-cluster-parameter-groups` |
| パラメータの中身（変更したものだけ） | `aws rds describe-db-parameters --db-parameter-group-name <g> --source user` / `describe-db-cluster-parameters` |
| サブネットグループ | `aws rds describe-db-subnet-groups` |
| オプショングループ | `aws rds describe-option-groups` |
| スナップショット | `aws rds describe-db-snapshots --snapshot-type manual` / `describe-db-cluster-snapshots` |
| RDS Proxy | `aws rds describe-db-proxies` / `describe-db-proxy-target-groups` |

### コマンド例

```bash
aws rds describe-db-instances \
  --query 'DBInstances[].{id:DBInstanceIdentifier,engine:Engine,ver:EngineVersion,class:DBInstanceClass,multiAZ:MultiAZ,storage:StorageType,size:AllocatedStorage,encrypted:StorageEncrypted,public:PubliclyAccessible,pg:DBParameterGroups[0].DBParameterGroupName,subnetGroup:DBSubnetGroup.DBSubnetGroupName,sgs:VpcSecurityGroups[].VpcSecurityGroupId,cluster:DBClusterIdentifier,backup:BackupRetentionPeriod}'

# 各パラメータグループで既定から変えた値
for g in $(aws rds describe-db-parameter-groups --query 'DBParameterGroups[?!starts_with(DBParameterGroupName,`default.`)].DBParameterGroupName' --output text); do
  echo "== $g"
  aws rds describe-db-parameters --db-parameter-group-name "$g" --source user \
    --query 'Parameters[].[ParameterName,ParameterValue,ApplyMethod]' --output text
done
```

### レスポンス例

```json
[
  {
    "id": "app-db-1",
    "engine": "aurora-mysql",
    "ver": "8.0.mysql_aurora.3.08.0",
    "class": "db.r6g.large",
    "multiAZ": false,
    "storage": "aurora",
    "size": 1,
    "encrypted": true,
    "public": false,
    "pg": "app-aurora-mysql80",
    "subnetGroup": "app-db-subnets",
    "sgs": ["sg-0db11111aaaa2222b"],
    "cluster": "app-db",
    "backup": 7
  }
]
```

```text
== app-mysql80
character_set_server	utf8mb4	pending-reboot
long_query_time	1	immediate
slow_query_log	1	immediate
```

## S3

S3 は「バケット一覧」と「バケットごとの設定取得（get-bucket-xxx）」に分かれる。設定がないものは `NoSuchBucketPolicy` / `NoSuchLifecycleConfiguration` などのエラーで返る点に注意。

| 取得したいもの | コマンド |
|---|---|
| バケット一覧 | `aws s3api list-buckets` |
| リージョン | `aws s3api get-bucket-location --bucket <b>` |
| バージョニング | `aws s3api get-bucket-versioning --bucket <b>` |
| 暗号化 | `aws s3api get-bucket-encryption --bucket <b>` |
| パブリックアクセスブロック | `aws s3api get-public-access-block --bucket <b>` |
| バケットポリシー | `aws s3api get-bucket-policy --bucket <b>` |
| 所有権（ACL 無効化） | `aws s3api get-bucket-ownership-controls --bucket <b>` |
| ライフサイクル | `aws s3api get-bucket-lifecycle-configuration --bucket <b>` |
| ログ / 通知 / レプリケーション / CORS / Webサイト | `get-bucket-logging` / `get-bucket-notification-configuration` / `get-bucket-replication` / `get-bucket-cors` / `get-bucket-website` |
| タグ | `aws s3api get-bucket-tagging --bucket <b>` |

### コマンド例

```bash
for b in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  echo "== $b"
  aws s3api get-bucket-location --bucket "$b"
  aws s3api get-bucket-versioning --bucket "$b"
  aws s3api get-bucket-encryption --bucket "$b" 2>/dev/null
  aws s3api get-public-access-block --bucket "$b" 2>/dev/null || echo "PublicAccessBlock: なし"
  aws s3api get-bucket-policy --bucket "$b" --query Policy --output text 2>/dev/null || echo "Policy: なし"
done
```

### レスポンス例

`list-buckets`:

```json
{
  "Buckets": [
    { "Name": "app-prod-assets", "CreationDate": "2024-04-01T02:15:30+00:00", "BucketRegion": "ap-northeast-1" },
    { "Name": "app-prod-logs", "CreationDate": "2024-04-01T02:16:02+00:00", "BucketRegion": "ap-northeast-1" }
  ],
  "Owner": { "ID": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
}
```

`get-bucket-location`（us-east-1 のときは `null`）:

```json
{ "LocationConstraint": "ap-northeast-1" }
```

`get-bucket-versioning`（一度も有効にしていないと `{}`）:

```json
{ "Status": "Enabled" }
```

`get-bucket-encryption`:

```json
{
  "ServerSideEncryptionConfiguration": {
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms",
          "KMSMasterKeyID": "arn:aws:kms:ap-northeast-1:123456789012:key/0abc1234-5678-90de-f123-4567890abcde"
        },
        "BucketKeyEnabled": true
      }
    ]
  }
}
```

`get-public-access-block`:

```json
{
  "PublicAccessBlockConfiguration": {
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }
}
```

`get-bucket-policy --query Policy --output text`（ポリシー本体は JSON 文字列）:

```json
{"Version":"2012-10-17","Statement":[{"Sid":"AllowCloudFrontOAC","Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::app-prod-assets/*","Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::123456789012:distribution/E1ABCDEFGHIJKL"}}}]}
```

---

# ネットワークの区画と通信の制御

## VPC

| 取得したいもの | コマンド |
|---|---|
| VPC | `aws ec2 describe-vpcs` |
| ルートテーブル | `aws ec2 describe-route-tables` |
| インターネットゲートウェイ | `aws ec2 describe-internet-gateways` |
| NAT ゲートウェイ | `aws ec2 describe-nat-gateways` |
| VPC エンドポイント | `aws ec2 describe-vpc-endpoints` |
| VPC ピアリング | `aws ec2 describe-vpc-peering-connections` |
| Transit Gateway アタッチメント | `aws ec2 describe-transit-gateway-attachments` |
| ネットワーク ACL | `aws ec2 describe-network-acls` |
| フローログ | `aws ec2 describe-flow-logs` |
| VPC の DNS 属性 | `aws ec2 describe-vpc-attribute --vpc-id <v> --attribute enableDnsHostnames`（`enableDnsSupport` も） |

### コマンド例

```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[].{id:VpcId,cidr:CidrBlock,extraCidrs:CidrBlockAssociationSet[].CidrBlock,default:IsDefault,name:Tags[?Key==`Name`]|[0].Value}'

# ルートテーブルとその経路・関連付け
aws ec2 describe-route-tables --filters Name=vpc-id,Values=vpc-0123456789abcdef0 \
  --query 'RouteTables[].{id:RouteTableId,name:Tags[?Key==`Name`]|[0].Value,subnets:Associations[].SubnetId,routes:Routes[].[DestinationCidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId||TransitGatewayId||VpcEndpointId]}'

aws ec2 describe-vpc-endpoints \
  --query 'VpcEndpoints[].{id:VpcEndpointId,service:ServiceName,type:VpcEndpointType,state:State,subnets:SubnetIds,rt:RouteTableIds}'
```

### レスポンス例

```json
[
  {
    "id": "vpc-0123456789abcdef0",
    "cidr": "10.0.0.0/16",
    "extraCidrs": ["10.0.0.0/16"],
    "default": false,
    "name": "app-prod"
  }
]
```

```json
[
  {
    "id": "rtb-0private111aaaa22",
    "name": "app-prod-private-a",
    "subnets": ["subnet-0aaa1111bbbb2222c"],
    "routes": [
      ["10.0.0.0/16", "local"],
      ["0.0.0.0/0", "nat-0abc1234def567890"],
      ["pl-61a54008", "vpce-0s3gw1111aaaa222"]
    ]
  }
]
```

```json
[
  {
    "id": "vpce-0s3gw1111aaaa222",
    "service": "com.amazonaws.ap-northeast-1.s3",
    "type": "Gateway",
    "state": "available",
    "subnets": [],
    "rt": ["rtb-0private111aaaa22"]
  }
]
```

## サブネット

| 取得したいもの | コマンド |
|---|---|
| サブネット | `aws ec2 describe-subnets`（`--filters Name=vpc-id,Values=<v>` で VPC ごと） |
| サブネットとルートテーブルの対応 | `aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=<s>` |
| サブネット内の ENI（何が使っているか） | `aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=<s>` |

### コマンド例

```bash
aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-0123456789abcdef0 \
  --query 'Subnets[].{id:SubnetId,name:Tags[?Key==`Name`]|[0].Value,az:AvailabilityZone,cidr:CidrBlock,freeIps:AvailableIpAddressCount,publicIpOnLaunch:MapPublicIpOnLaunch}' \
  --output table

# サブネットを使っている ENI（EC2 / RDS / Lambda / ALB / Fargate など）
aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=subnet-0aaa1111bbbb2222c \
  --query 'NetworkInterfaces[].{eni:NetworkInterfaceId,ip:PrivateIpAddress,type:InterfaceType,desc:Description,sgs:Groups[].GroupId}'
```

### レスポンス例

```text
------------------------------------------------------------------------------------------------------------
|                                              DescribeSubnets                                             |
+------------------+----------------+----------+----------------------------+-------------------------+-------------------+
|        az        |      cidr      | freeIps  |             id             |          name           | publicIpOnLaunch  |
+------------------+----------------+----------+----------------------------+-------------------------+-------------------+
|  ap-northeast-1a |  10.0.1.0/24   |  245     |  subnet-0aaa1111bbbb2222c  |  app-prod-private-a     |  False            |
|  ap-northeast-1c |  10.0.2.0/24   |  248     |  subnet-0ddd3333eeee4444f  |  app-prod-private-c     |  False            |
|  ap-northeast-1a |  10.0.101.0/24 |  250     |  subnet-0pub1111aaaa2222b  |  app-prod-public-a      |  True             |
+------------------+----------------+----------+----------------------------+-------------------------+-------------------+
```

```json
[
  {
    "eni": "eni-0abc1234def567890",
    "ip": "10.0.1.42",
    "type": "interface",
    "desc": "RDSNetworkInterface",
    "sgs": ["sg-0db11111aaaa2222b"]
  }
]
```

## セキュリティグループ

| 取得したいもの | コマンド |
|---|---|
| セキュリティグループ（ルール込み） | `aws ec2 describe-security-groups` |
| ルール単位の一覧（ルールIDつき） | `aws ec2 describe-security-group-rules` |
| SG を使っている ENI | `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<sg>` |
| 参照元 SG（どこから参照されているか） | `aws ec2 describe-security-group-references --group-id <sg>`（VPC ピア越しの参照） |

### コマンド例

```bash
aws ec2 describe-security-groups --filters Name=vpc-id,Values=vpc-0123456789abcdef0 \
  --query 'SecurityGroups[].{id:GroupId,name:GroupName,desc:Description}'

# ルールを 1 行ずつ（受信 / 送信、ポート、許可元）
aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-0db11111aaaa2222b \
  --query 'SecurityGroupRules[].{rule:SecurityGroupRuleId,egress:IsEgress,proto:IpProtocol,from:FromPort,to:ToPort,cidr:CidrIpv4,srcSg:ReferencedGroupInfo.GroupId,desc:Description}'
```

### レスポンス例

`describe-security-groups`（`--query` なし、抜粋）:

```json
{
  "SecurityGroups": [
    {
      "GroupId": "sg-0db11111aaaa2222b",
      "GroupName": "app-db-sg",
      "Description": "Aurora access from app",
      "VpcId": "vpc-0123456789abcdef0",
      "IpPermissions": [
        {
          "IpProtocol": "tcp",
          "FromPort": 3306,
          "ToPort": 3306,
          "UserIdGroupPairs": [{ "GroupId": "sg-0api1111aaaa2222b", "UserId": "123456789012" }],
          "IpRanges": [],
          "Ipv6Ranges": [],
          "PrefixListIds": []
        }
      ],
      "IpPermissionsEgress": [
        { "IpProtocol": "-1", "IpRanges": [{ "CidrIp": "0.0.0.0/0" }], "UserIdGroupPairs": [], "Ipv6Ranges": [], "PrefixListIds": [] }
      ]
    }
  ]
}
```

`describe-security-group-rules`（`--query` で抜粋）:

```json
[
  { "rule": "sgr-0in11111aaaa2222", "egress": false, "proto": "tcp", "from": 3306, "to": 3306, "cidr": null, "srcSg": "sg-0api1111aaaa2222b", "desc": "from api" },
  { "rule": "sgr-0out1111aaaa222", "egress": true, "proto": "-1", "from": -1, "to": -1, "cidr": "0.0.0.0/0", "srcSg": null, "desc": null }
]
```

---

# サーバーを管理しない実行環境と、メッセージによる処理の切り離し

## Lambda

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| 関数 | `aws lambda list-functions` | `aws lambda get-function-configuration --function-name <f>` / `get-function`（コードの取得URL込み） |
| エイリアス / バージョン | `aws lambda list-aliases --function-name <f>` / `list-versions-by-function` | — |
| リソースベースポリシー（誰が呼べるか） | — | `aws lambda get-policy --function-name <f>` |
| イベントソース（SQS / DynamoDB / Kinesis など） | `aws lambda list-event-source-mappings` | `get-event-source-mapping --uuid <id>` |
| 関数 URL | `aws lambda list-function-url-configs --function-name <f>` | — |
| 予約同時実行数 | — | `aws lambda get-function-concurrency --function-name <f>` |
| レイヤー | `aws lambda list-layers` | `get-layer-version` |

### コマンド例

```bash
aws lambda list-functions \
  --query 'Functions[].{name:FunctionName,runtime:Runtime,arch:Architectures[0],mem:MemorySize,timeout:Timeout,role:Role,vpc:VpcConfig.SubnetIds,modified:LastModified}'

for f in $(aws lambda list-functions --query 'Functions[].FunctionName' --output text); do
  echo "== $f"
  aws lambda get-function-configuration --function-name "$f" \
    --query '{handler:Handler,env:Environment.Variables,layers:Layers[].Arn,dlq:DeadLetterConfig.TargetArn,logGroup:LoggingConfig.LogGroup}'
  aws lambda get-policy --function-name "$f" --query Policy --output text 2>/dev/null || echo "Policy: なし"
done

aws lambda list-event-source-mappings \
  --query 'EventSourceMappings[].{fn:FunctionArn,src:EventSourceArn,state:State,batch:BatchSize}'
```

### レスポンス例

```json
[
  {
    "name": "order-worker",
    "runtime": "python3.13",
    "arch": "arm64",
    "mem": 512,
    "timeout": 60,
    "role": "arn:aws:iam::123456789012:role/order-worker-role",
    "vpc": ["subnet-0aaa1111bbbb2222c", "subnet-0ddd3333eeee4444f"],
    "modified": "2026-09-12T03:21:45.000+0000"
  }
]
```

```json
{
  "handler": "app.handler",
  "env": { "QUEUE_URL": "https://sqs.ap-northeast-1.amazonaws.com/123456789012/order-queue", "LOG_LEVEL": "INFO" },
  "layers": ["arn:aws:lambda:ap-northeast-1:123456789012:layer:common:7"],
  "dlq": null,
  "logGroup": "/aws/lambda/order-worker"
}
```

```json
[
  {
    "fn": "arn:aws:lambda:ap-northeast-1:123456789012:function:order-worker",
    "src": "arn:aws:sqs:ap-northeast-1:123456789012:order-queue",
    "state": "Enabled",
    "batch": 10
  }
]
```

## API Gateway

REST API（v1）と HTTP API / WebSocket API（v2）でコマンドが分かれる。両方を取る。

| 取得したいもの | REST API（`apigateway`） | HTTP / WebSocket API（`apigatewayv2`） |
|---|---|---|
| API 一覧 | `get-rest-apis` | `get-apis` |
| リソース・ルート | `get-resources --rest-api-id <id> --embed methods` | `get-routes --api-id <id>` |
| 統合（バックエンド） | `get-integration --rest-api-id <id> --resource-id <r> --http-method GET` | `get-integrations --api-id <id>` |
| ステージ | `get-stages --rest-api-id <id>` | `get-stages --api-id <id>` |
| オーソライザー | `get-authorizers --rest-api-id <id>` | `get-authorizers --api-id <id>` |
| カスタムドメイン | `get-domain-names` / `get-base-path-mappings` | `get-domain-names` / `get-api-mappings` |
| 使用量プラン / API キー | `get-usage-plans` / `get-api-keys` | — |
| VPC リンク | `get-vpc-links` | `get-vpc-links` |

### コマンド例

```bash
# REST API
for id in $(aws apigateway get-rest-apis --query 'items[].id' --output text); do
  echo "== $id"
  aws apigateway get-resources --rest-api-id "$id" --embed methods \
    --query 'items[].{path:path,methods:keys(resourceMethods||`{}`)}'
  aws apigateway get-stages --rest-api-id "$id" \
    --query 'item[].{stage:stageName,deployment:deploymentId,waf:webAclArn,vars:variables}'
done

# HTTP API
for id in $(aws apigatewayv2 get-apis --query 'Items[].ApiId' --output text); do
  aws apigatewayv2 get-routes --api-id "$id" --query 'Items[].{route:RouteKey,target:Target,auth:AuthorizationType}'
  aws apigatewayv2 get-integrations --api-id "$id" --query 'Items[].{id:IntegrationId,type:IntegrationType,uri:IntegrationUri}'
done
```

### レスポンス例

`apigateway get-rest-apis`:

```json
{
  "items": [
    {
      "id": "a1b2c3d4e5",
      "name": "public-api",
      "createdDate": "2025-02-10T10:00:00+09:00",
      "apiKeySource": "HEADER",
      "endpointConfiguration": { "types": ["REGIONAL"] },
      "disableExecuteApiEndpoint": false
    }
  ]
}
```

`get-resources`（`--query` で抜粋）:

```json
[
  { "path": "/", "methods": [] },
  { "path": "/orders", "methods": ["GET", "POST"] },
  { "path": "/orders/{id}", "methods": ["GET"] }
]
```

`apigatewayv2 get-apis`:

```json
{
  "Items": [
    {
      "ApiId": "x9y8z7w6v5",
      "Name": "internal-http-api",
      "ProtocolType": "HTTP",
      "ApiEndpoint": "https://x9y8z7w6v5.execute-api.ap-northeast-1.amazonaws.com",
      "RouteSelectionExpression": "$request.method $request.path",
      "CreatedDate": "2025-06-01T01:00:00+00:00"
    }
  ]
}
```

`apigatewayv2 get-routes`（抜粋）:

```json
[
  { "route": "GET /health", "target": "integrations/abc1234", "auth": "NONE" },
  { "route": "POST /jobs", "target": "integrations/def5678", "auth": "JWT" }
]
```

## SNS

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| トピック | `aws sns list-topics` | `aws sns get-topic-attributes --topic-arn <arn>` |
| サブスクリプション | `aws sns list-subscriptions` / `list-subscriptions-by-topic --topic-arn <arn>` | `aws sns get-subscription-attributes --subscription-arn <arn>`（フィルターポリシーなど） |
| タグ | — | `aws sns list-tags-for-resource --resource-arn <arn>` |

### コマンド例

```bash
for t in $(aws sns list-topics --query 'Topics[].TopicArn' --output text); do
  echo "== $t"
  aws sns get-topic-attributes --topic-arn "$t" \
    --query 'Attributes.{name:DisplayName,kms:KmsMasterKeyId,fifo:FifoTopic,subs:SubscriptionsConfirmed,policy:Policy}'
  aws sns list-subscriptions-by-topic --topic-arn "$t" \
    --query 'Subscriptions[].{protocol:Protocol,endpoint:Endpoint,arn:SubscriptionArn}'
done
```

### レスポンス例

`list-topics`:

```json
{
  "Topics": [
    { "TopicArn": "arn:aws:sns:ap-northeast-1:123456789012:order-events" },
    { "TopicArn": "arn:aws:sns:ap-northeast-1:123456789012:alarm-notify" }
  ]
}
```

`get-topic-attributes`（`--query` なし、抜粋。値はすべて文字列）:

```json
{
  "Attributes": {
    "TopicArn": "arn:aws:sns:ap-northeast-1:123456789012:order-events",
    "DisplayName": "",
    "Owner": "123456789012",
    "SubscriptionsConfirmed": "2",
    "SubscriptionsPending": "0",
    "KmsMasterKeyId": "alias/aws/sns",
    "Policy": "{\"Version\":\"2008-10-17\",\"Id\":\"__default_policy_ID\",\"Statement\":[...]}",
    "EffectiveDeliveryPolicy": "{\"http\":{\"defaultHealthyRetryPolicy\":{...}}}"
  }
}
```

`list-subscriptions-by-topic`（抜粋）:

```json
[
  {
    "protocol": "sqs",
    "endpoint": "arn:aws:sqs:ap-northeast-1:123456789012:order-queue",
    "arn": "arn:aws:sns:ap-northeast-1:123456789012:order-events:0abc1234-5678-90de-f123-4567890abcde"
  },
  {
    "protocol": "email",
    "endpoint": "ops@example.com",
    "arn": "PendingConfirmation"
  }
]
```

## SQS

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| キュー | `aws sqs list-queues` | `aws sqs get-queue-attributes --queue-url <url> --attribute-names All` |
| DLQ を参照しているキュー | — | `aws sqs list-dead-letter-source-queues --queue-url <dlq-url>` |
| タグ | — | `aws sqs list-queue-tags --queue-url <url>` |

### コマンド例

```bash
for q in $(aws sqs list-queues --query 'QueueUrls[]' --output text); do
  echo "== $q"
  aws sqs get-queue-attributes --queue-url "$q" --attribute-names All \
    --query 'Attributes.{visibility:VisibilityTimeout,retention:MessageRetentionPeriod,delay:DelaySeconds,wait:ReceiveMessageWaitTimeSeconds,redrive:RedrivePolicy,fifo:FifoQueue,sse:SqsManagedSseEnabled,kms:KmsMasterKeyId,msgs:ApproximateNumberOfMessages}'
done
```

### レスポンス例

`list-queues`（キューが 1 つもないと出力が空になる）:

```json
{
  "QueueUrls": [
    "https://sqs.ap-northeast-1.amazonaws.com/123456789012/order-queue",
    "https://sqs.ap-northeast-1.amazonaws.com/123456789012/order-queue-dlq"
  ]
}
```

`get-queue-attributes`（`--query` なし、抜粋。値はすべて文字列）:

```json
{
  "Attributes": {
    "QueueArn": "arn:aws:sqs:ap-northeast-1:123456789012:order-queue",
    "ApproximateNumberOfMessages": "0",
    "ApproximateNumberOfMessagesNotVisible": "0",
    "VisibilityTimeout": "360",
    "MessageRetentionPeriod": "345600",
    "DelaySeconds": "0",
    "ReceiveMessageWaitTimeSeconds": "20",
    "MaximumMessageSize": "262144",
    "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:ap-northeast-1:123456789012:order-queue-dlq\",\"maxReceiveCount\":5}",
    "SqsManagedSseEnabled": "true",
    "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[...]}"
  }
}
```

---

# 入口での配信・負荷分散・攻撃の遮断

## CloudFront

グローバルサービス。`--region` は不要（指定しても us-east-1 扱い）。

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| ディストリビューション | `aws cloudfront list-distributions` | `aws cloudfront get-distribution-config --id <id>` |
| キャッシュポリシー | `aws cloudfront list-cache-policies --type custom` | `get-cache-policy --id <id>` |
| オリジンリクエストポリシー | `aws cloudfront list-origin-request-policies --type custom` | `get-origin-request-policy --id <id>` |
| レスポンスヘッダーポリシー | `aws cloudfront list-response-headers-policies --type custom` | `get-response-headers-policy --id <id>` |
| OAC | `aws cloudfront list-origin-access-controls` | `get-origin-access-control --id <id>` |
| CloudFront Functions | `aws cloudfront list-functions` | `describe-function --name <n>` / `get-function --name <n> <outfile>` |

### コマンド例

```bash
aws cloudfront list-distributions \
  --query 'DistributionList.Items[].{id:Id,domain:DomainName,aliases:Aliases.Items,enabled:Enabled,origins:Origins.Items[].DomainName,waf:WebACLId,cert:ViewerCertificate.ACMCertificateArn,price:PriceClass}'

for id in $(aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text); do
  aws cloudfront get-distribution-config --id "$id" \
    --query 'DistributionConfig.{default:DefaultCacheBehavior.{origin:TargetOriginId,viewer:ViewerProtocolPolicy,cachePolicy:CachePolicyId,fn:FunctionAssociations.Items},behaviors:CacheBehaviors.Items[].{path:PathPattern,origin:TargetOriginId,cachePolicy:CachePolicyId},logging:Logging}'
done
```

### レスポンス例

`list-distributions`（`--query` で抜粋）:

```json
[
  {
    "id": "E1ABCDEFGHIJKL",
    "domain": "d111111abcdef8.cloudfront.net",
    "aliases": ["www.example.com"],
    "enabled": true,
    "origins": ["app-prod-assets.s3.ap-northeast-1.amazonaws.com", "app-prod-alb-1234567890.ap-northeast-1.elb.amazonaws.com"],
    "waf": "arn:aws:wafv2:us-east-1:123456789012:global/webacl/cf-acl/0abc1234-5678-90de-f123-4567890abcde",
    "cert": "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555",
    "price": "PriceClass_200"
  }
]
```

`get-distribution-config`（`--query` なしの外枠。更新時に使う `ETag` が付く）:

```json
{
  "ETag": "E2QWRUHEXAMPLE",
  "DistributionConfig": {
    "CallerReference": "cli-1700000000",
    "Aliases": { "Quantity": 1, "Items": ["www.example.com"] },
    "Origins": {
      "Quantity": 2,
      "Items": [
        {
          "Id": "s3-assets",
          "DomainName": "app-prod-assets.s3.ap-northeast-1.amazonaws.com",
          "S3OriginConfig": { "OriginAccessIdentity": "" },
          "OriginAccessControlId": "E3OACEXAMPLE"
        }
      ]
    },
    "DefaultCacheBehavior": {
      "TargetOriginId": "alb-app",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    },
    "WebACLId": "arn:aws:wafv2:us-east-1:123456789012:global/webacl/cf-acl/0abc1234-...",
    "Enabled": true
  }
}
```

## ALB（Elastic Load Balancing v2）

ALB / NLB / GWLB は `elbv2`。CLB は `elb`（別コマンド）。

| 取得したいもの | コマンド |
|---|---|
| ロードバランサー | `aws elbv2 describe-load-balancers` |
| LB の属性（アクセスログ、削除保護、アイドルタイムアウトなど） | `aws elbv2 describe-load-balancer-attributes --load-balancer-arn <arn>` |
| リスナー | `aws elbv2 describe-listeners --load-balancer-arn <arn>` |
| リスナールール | `aws elbv2 describe-rules --listener-arn <arn>` |
| リスナーの追加証明書 | `aws elbv2 describe-listener-certificates --listener-arn <arn>` |
| ターゲットグループ | `aws elbv2 describe-target-groups` |
| ターゲットグループの属性 | `aws elbv2 describe-target-group-attributes --target-group-arn <arn>` |
| ターゲットの状態 | `aws elbv2 describe-target-health --target-group-arn <arn>` |
| TLS ポリシー | `aws elbv2 describe-ssl-policies --names <n>` |

### コマンド例

```bash
for lb in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[?Type==`application`].LoadBalancerArn' --output text); do
  echo "== $lb"
  aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$lb" \
    --query 'Attributes[?Key==`access_logs.s3.enabled`||Key==`deletion_protection.enabled`||Key==`idle_timeout.timeout_seconds`]'
  for l in $(aws elbv2 describe-listeners --load-balancer-arn "$lb" --query 'Listeners[].ListenerArn' --output text); do
    aws elbv2 describe-rules --listener-arn "$l" \
      --query 'Rules[].{prio:Priority,cond:Conditions[].{f:Field,v:Values||HostHeaderConfig.Values||PathPatternConfig.Values},action:Actions[].{type:Type,tg:TargetGroupArn}}'
  done
done

for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
  aws elbv2 describe-target-health --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].{target:Target.Id,port:Target.Port,state:TargetHealth.State,reason:TargetHealth.Reason}'
done
```

### レスポンス例

`describe-load-balancers`（抜粋）:

```json
{
  "LoadBalancers": [
    {
      "LoadBalancerArn": "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:loadbalancer/app/app-prod-alb/0123456789abcdef",
      "DNSName": "app-prod-alb-1234567890.ap-northeast-1.elb.amazonaws.com",
      "LoadBalancerName": "app-prod-alb",
      "Scheme": "internet-facing",
      "VpcId": "vpc-0123456789abcdef0",
      "State": { "Code": "active" },
      "Type": "application",
      "AvailabilityZones": [
        { "ZoneName": "ap-northeast-1a", "SubnetId": "subnet-0pub1111aaaa2222b" },
        { "ZoneName": "ap-northeast-1c", "SubnetId": "subnet-0pub3333cccc4444d" }
      ],
      "SecurityGroups": ["sg-0alb1111aaaa2222b"],
      "IpAddressType": "ipv4"
    }
  ]
}
```

`describe-listeners`（抜粋）:

```json
{
  "Listeners": [
    {
      "ListenerArn": "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:listener/app/app-prod-alb/0123456789abcdef/fedcba9876543210",
      "Port": 443,
      "Protocol": "HTTPS",
      "Certificates": [{ "CertificateArn": "arn:aws:acm:ap-northeast-1:123456789012:certificate/aaaa-bbbb" }],
      "SslPolicy": "ELBSecurityPolicy-TLS13-1-2-2021-06",
      "DefaultActions": [{ "Type": "forward", "TargetGroupArn": "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/api-tg/0123456789abcdef" }]
    }
  ]
}
```

`describe-target-health`（`--query` で抜粋）:

```json
[
  { "target": "10.0.11.23", "port": 8080, "state": "healthy", "reason": null },
  { "target": "10.0.12.41", "port": 8080, "state": "unhealthy", "reason": "Target.ResponseCodeMismatch" }
]
```

## WAF（wafv2）

`--scope` が必須。ALB / API Gateway / AppSync / Cognito 用は `REGIONAL`、CloudFront 用は `CLOUDFRONT`（このときは `--region us-east-1` が必須）。

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| Web ACL | `aws wafv2 list-web-acls --scope REGIONAL` | `aws wafv2 get-web-acl --scope REGIONAL --name <n> --id <id>` |
| Web ACL の関連付け先 | — | `aws wafv2 list-resources-for-web-acl --web-acl-arn <arn>`（REGIONAL のみ。CloudFront は distribution 側の `WebACLId` を見る） |
| ルールグループ | `aws wafv2 list-rule-groups --scope ...` | `get-rule-group` |
| IP セット | `aws wafv2 list-ip-sets --scope ...` | `get-ip-set` |
| 正規表現セット | `aws wafv2 list-regex-pattern-sets --scope ...` | `get-regex-pattern-set` |
| ログ設定 | `aws wafv2 list-logging-configurations --scope ...` | `get-logging-configuration --resource-arn <acl-arn>` |
| リソースから逆引き | — | `aws wafv2 get-web-acl-for-resource --resource-arn <alb-arn>` |

### コマンド例

```bash
# REGIONAL（ALB / API Gateway 向け）
aws wafv2 list-web-acls --scope REGIONAL --output text \
  --query 'WebACLs[].[Name,Id,ARN]' | while read -r name id arn; do
  echo "== $name"
  aws wafv2 get-web-acl --scope REGIONAL --name "$name" --id "$id" \
    --query 'WebACL.{default:DefaultAction,rules:Rules[].{name:Name,prio:Priority,stmt:keys(Statement),action:Action||OverrideAction}}'
  aws wafv2 list-resources-for-web-acl --web-acl-arn "$arn"
done

# CLOUDFRONT 向け（us-east-1 固定）
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1
```

### レスポンス例

`list-web-acls`:

```json
{
  "NextMarker": "alb-acl",
  "WebACLs": [
    {
      "Name": "alb-acl",
      "Id": "0abc1234-5678-90de-f123-4567890abcde",
      "Description": "",
      "LockToken": "11111111-2222-3333-4444-555555555555",
      "ARN": "arn:aws:wafv2:ap-northeast-1:123456789012:regional/webacl/alb-acl/0abc1234-5678-90de-f123-4567890abcde"
    }
  ]
}
```

`get-web-acl`（`--query` で抜粋）:

```json
{
  "default": { "Allow": {} },
  "rules": [
    { "name": "AWS-AWSManagedRulesCommonRuleSet", "prio": 0, "stmt": ["ManagedRuleGroupStatement"], "action": { "None": {} } },
    { "name": "rate-limit", "prio": 1, "stmt": ["RateBasedStatement"], "action": { "Block": {} } },
    { "name": "block-ipset", "prio": 2, "stmt": ["IPSetReferenceStatement"], "action": { "Block": {} } }
  ]
}
```

`list-resources-for-web-acl`:

```json
{
  "ResourceArns": [
    "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:loadbalancer/app/app-prod-alb/0123456789abcdef"
  ]
}
```

---

# インフラ全体をコードで構築する土台と、権限の管理

## CloudFormation

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| スタック | `aws cloudformation list-stacks --stack-status-filter ...` | `aws cloudformation describe-stacks --stack-name <s>`（パラメータ、出力、タグ） |
| スタック内のリソース | `aws cloudformation list-stack-resources --stack-name <s>` | `describe-stack-resource --stack-name <s> --logical-resource-id <id>` |
| テンプレート本体 | — | `aws cloudformation get-template --stack-name <s>` |
| 出力の Export | `aws cloudformation list-exports` | `list-imports --export-name <n>` |
| ドリフト | `detect-stack-drift` → `describe-stack-resource-drifts --stack-name <s>` | — |
| StackSet | `aws cloudformation list-stack-sets` | `describe-stack-set` / `list-stack-instances` |

### コマンド例

```bash
# 削除済みを除く全スタック
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE IMPORT_COMPLETE \
  --query 'StackSummaries[].{name:StackName,status:StackStatus,updated:LastUpdatedTime,drift:DriftInformation.StackDriftStatus}'

s=app-prod-network
aws cloudformation describe-stacks --stack-name "$s" \
  --query 'Stacks[0].{params:Parameters,outputs:Outputs[].{k:OutputKey,v:OutputValue,export:ExportName},role:RoleARN,termProtect:EnableTerminationProtection}'
aws cloudformation list-stack-resources --stack-name "$s" \
  --query 'StackResourceSummaries[].[LogicalResourceId,ResourceType,PhysicalResourceId,ResourceStatus]' --output text
aws cloudformation get-template --stack-name "$s" --query TemplateBody --output text > "$s.yaml"
```

### レスポンス例

`list-stacks`（`--query` で抜粋）:

```json
[
  { "name": "app-prod-network", "status": "UPDATE_COMPLETE", "updated": "2026-08-20T05:12:33.123000+00:00", "drift": "IN_SYNC" },
  { "name": "app-prod-ecs", "status": "CREATE_COMPLETE", "updated": null, "drift": "NOT_CHECKED" }
]
```

`describe-stacks`（`--query` で抜粋）:

```json
{
  "params": [
    { "ParameterKey": "Env", "ParameterValue": "prod" },
    { "ParameterKey": "VpcCidr", "ParameterValue": "10.0.0.0/16" }
  ],
  "outputs": [
    { "k": "VpcId", "v": "vpc-0123456789abcdef0", "export": "app-prod-VpcId" }
  ],
  "role": null,
  "termProtect": true
}
```

`list-stack-resources`（text 出力）:

```text
Vpc	AWS::EC2::VPC	vpc-0123456789abcdef0	CREATE_COMPLETE
PrivateSubnetA	AWS::EC2::Subnet	subnet-0aaa1111bbbb2222c	CREATE_COMPLETE
DbSecurityGroup	AWS::EC2::SecurityGroup	sg-0db11111aaaa2222b	UPDATE_COMPLETE
```

## IAM

グローバルサービス。個別に list していくこともできるが、**`get-account-authorization-details` を使うとユーザー・グループ・ロール・カスタマー管理ポリシーとその中身を 1 回でまとめて取れる**。

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| 全部まとめて | `aws iam get-account-authorization-details` | — |
| ロール | `aws iam list-roles` | `get-role --role-name <r>`（信頼ポリシー） |
| ロールに付いたポリシー | `list-attached-role-policies --role-name <r>`（管理） / `list-role-policies`（インライン） | `get-role-policy --role-name <r> --policy-name <p>` |
| ユーザー | `aws iam list-users` | `list-attached-user-policies` / `list-user-policies` / `list-groups-for-user` / `list-access-keys` / `list-mfa-devices` |
| グループ | `aws iam list-groups` | `get-group`（メンバー） / `list-attached-group-policies` |
| カスタマー管理ポリシー | `aws iam list-policies --scope Local` | `get-policy-version --policy-arn <arn> --version-id <v>` |
| インスタンスプロファイル | `aws iam list-instance-profiles` | — |
| OIDC / SAML プロバイダー | `list-open-id-connect-providers` / `list-saml-providers` | `get-open-id-connect-provider` |
| 認証情報レポート | `generate-credential-report` → `get-credential-report` | — |

### コマンド例

```bash
# まとめて取得（ファイルに保存して jq で見るのが楽）
aws iam get-account-authorization-details \
  --filter User Role Group LocalManagedPolicy > iam-auth-details.json

# ロールごとの信頼先と付いているポリシー
for r in $(aws iam list-roles --query 'Roles[?!starts_with(Path,`/aws-service-role/`)].RoleName' --output text); do
  echo "== $r"
  aws iam get-role --role-name "$r" --query 'Role.AssumeRolePolicyDocument.Statement[].Principal'
  aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn'
  aws iam list-role-policies --role-name "$r" --query 'PolicyNames'
done

# カスタマー管理ポリシーの現行バージョンの中身
aws iam list-policies --scope Local --query 'Policies[].[Arn,DefaultVersionId]' --output text |
while read -r arn ver; do
  aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document'
done
```

### レスポンス例

`list-roles`（抜粋。ポリシー文書は CLI が URL デコードして JSON で返す）:

```json
{
  "Roles": [
    {
      "Path": "/",
      "RoleName": "api-task-role",
      "RoleId": "AROAEXAMPLEID1234567",
      "Arn": "arn:aws:iam::123456789012:role/api-task-role",
      "CreateDate": "2025-01-15T04:00:00+00:00",
      "AssumeRolePolicyDocument": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Principal": { "Service": "ecs-tasks.amazonaws.com" }, "Action": "sts:AssumeRole" }
        ]
      },
      "MaxSessionDuration": 3600
    }
  ]
}
```

`get-account-authorization-details`（構造の抜粋）:

```json
{
  "UserDetailList": [
    {
      "UserName": "ci-deployer",
      "Arn": "arn:aws:iam::123456789012:user/ci-deployer",
      "GroupList": ["deployers"],
      "AttachedManagedPolicies": [],
      "UserPolicyList": []
    }
  ],
  "GroupDetailList": [
    {
      "GroupName": "deployers",
      "AttachedManagedPolicies": [{ "PolicyName": "deploy-policy", "PolicyArn": "arn:aws:iam::123456789012:policy/deploy-policy" }]
    }
  ],
  "RoleDetailList": [
    {
      "RoleName": "api-task-role",
      "AssumeRolePolicyDocument": { "Version": "2012-10-17", "Statement": [ ... ] },
      "InstanceProfileList": [],
      "RolePolicyList": [
        { "PolicyName": "s3-read", "PolicyDocument": { "Version": "2012-10-17", "Statement": [ ... ] } }
      ],
      "AttachedManagedPolicies": [{ "PolicyName": "AmazonSSMReadOnlyAccess", "PolicyArn": "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess" }]
    }
  ],
  "Policies": [
    {
      "PolicyName": "deploy-policy",
      "Arn": "arn:aws:iam::123456789012:policy/deploy-policy",
      "DefaultVersionId": "v3",
      "AttachmentCount": 1,
      "PolicyVersionList": [
        { "VersionId": "v3", "IsDefaultVersion": true, "Document": { "Version": "2012-10-17", "Statement": [ ... ] } }
      ]
    }
  ]
}
```

---

# ビルド・デプロイ・イメージ作成の自動化

## CodeBuild

一覧は名前だけ返るので、`batch-get-*` で設定を取る（1 回 100 件まで）。

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| プロジェクト | `aws codebuild list-projects` | `aws codebuild batch-get-projects --names <n...>` |
| ビルド履歴 | `aws codebuild list-builds-for-project --project-name <n>` | `batch-get-builds --ids <id...>` |
| レポートグループ | `aws codebuild list-report-groups` | `batch-get-report-groups` |
| ソース認証情報 | `aws codebuild list-source-credentials` | — |
| フリート | `aws codebuild list-fleets` | `batch-get-fleets` |

### コマンド例

```bash
aws codebuild batch-get-projects \
  --names $(aws codebuild list-projects --query 'projects[]' --output text) \
  --query 'projects[].{name:name,source:source.{type:type,location:location,buildspec:buildspec},image:environment.image,compute:environment.computeType,privileged:environment.privilegedMode,role:serviceRole,vpc:vpcConfig.subnets,artifacts:artifacts.type,logs:logsConfig.cloudWatchLogs.groupName}'
```

### レスポンス例

`list-projects`:

```json
{
  "projects": ["api-build", "web-build"]
}
```

`batch-get-projects`（`--query` で抜粋）:

```json
[
  {
    "name": "api-build",
    "source": { "type": "CODEPIPELINE", "location": null, "buildspec": "buildspec.yml" },
    "image": "aws/codebuild/amazonlinux-aarch64-standard:3.0",
    "compute": "BUILD_GENERAL1_SMALL",
    "privileged": true,
    "role": "arn:aws:iam::123456789012:role/codebuild-api-build-role",
    "vpc": null,
    "artifacts": "CODEPIPELINE",
    "logs": "/codebuild/api-build"
  }
]
```

## CodeDeploy

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| アプリケーション | `aws deploy list-applications` | `aws deploy batch-get-applications --application-names <n...>` |
| デプロイグループ | `aws deploy list-deployment-groups --application-name <a>` | `aws deploy batch-get-deployment-groups --application-name <a> --deployment-group-names <g...>` |
| デプロイ設定（カスタム含む） | `aws deploy list-deployment-configs` | `get-deployment-config --deployment-config-name <n>` |
| デプロイ履歴 | `aws deploy list-deployments --application-name <a> --deployment-group-name <g>` | `batch-get-deployments --deployment-ids <id...>` |
| オンプレインスタンス | `aws deploy list-on-premises-instances` | `batch-get-on-premises-instances` |

### コマンド例

```bash
for app in $(aws deploy list-applications --query 'applications[]' --output text); do
  echo "== $app"
  groups=$(aws deploy list-deployment-groups --application-name "$app" --query 'deploymentGroups[]' --output text)
  [ -n "$groups" ] && aws deploy batch-get-deployment-groups --application-name "$app" \
    --deployment-group-names $groups \
    --query 'deploymentGroupsInfo[].{group:deploymentGroupName,platform:computePlatform,config:deploymentConfigName,role:serviceRoleArn,style:deploymentStyle,ecs:ecsServices,asg:autoScalingGroups[].name,ec2Tags:ec2TagFilters,rollback:autoRollbackConfiguration}'
done
```

### レスポンス例

`list-applications`:

```json
{
  "applications": ["api-ecs-app", "batch-ec2-app"]
}
```

`list-deployment-groups`:

```json
{
  "applicationName": "api-ecs-app",
  "deploymentGroups": ["api-prod"]
}
```

`batch-get-deployment-groups`（`--query` で抜粋）:

```json
[
  {
    "group": "api-prod",
    "platform": "ECS",
    "config": "CodeDeployDefault.ECSCanary10Percent5Minutes",
    "role": "arn:aws:iam::123456789012:role/codedeploy-ecs-role",
    "style": { "deploymentType": "BLUE_GREEN", "deploymentOption": "WITH_TRAFFIC_CONTROL" },
    "ecs": [{ "serviceName": "api", "clusterName": "app-prod" }],
    "asg": [],
    "ec2Tags": [],
    "rollback": { "enabled": true, "events": ["DEPLOYMENT_FAILURE"] }
  }
]
```

## CodePipeline

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| パイプライン | `aws codepipeline list-pipelines` | `aws codepipeline get-pipeline --name <n>`（ステージ・アクションの定義） |
| 現在の状態 | — | `aws codepipeline get-pipeline-state --name <n>` |
| 実行履歴 | `aws codepipeline list-pipeline-executions --pipeline-name <n>` | `get-pipeline-execution` |
| Webhook | `aws codepipeline list-webhooks` | — |
| ソース接続（GitHub など） | `aws codeconnections list-connections` | `get-connection --connection-arn <arn>` |

### コマンド例

```bash
for p in $(aws codepipeline list-pipelines --query 'pipelines[].name' --output text); do
  echo "== $p"
  aws codepipeline get-pipeline --name "$p" \
    --query 'pipeline.{role:roleArn,type:pipelineType,store:artifactStore.location,stages:stages[].{stage:name,actions:actions[].{name:name,provider:actionTypeId.provider,config:configuration}}}'
  aws codepipeline get-pipeline-state --name "$p" \
    --query 'stageStates[].{stage:stageName,status:latestExecution.status}'
done
```

### レスポンス例

`list-pipelines`:

```json
{
  "pipelines": [
    {
      "name": "api-pipeline",
      "version": 5,
      "pipelineType": "V2",
      "executionMode": "QUEUED",
      "created": "2025-03-01T10:00:00.000000+09:00",
      "updated": "2026-07-14T15:20:00.000000+09:00"
    }
  ]
}
```

`get-pipeline`（`--query` で抜粋）:

```json
{
  "role": "arn:aws:iam::123456789012:role/codepipeline-api-role",
  "type": "V2",
  "store": "codepipeline-ap-northeast-1-123456789012",
  "stages": [
    {
      "stage": "Source",
      "actions": [{ "name": "Source", "provider": "CodeStarSourceConnection", "config": { "ConnectionArn": "arn:aws:codeconnections:ap-northeast-1:123456789012:connection/abcd-1234", "FullRepositoryId": "example-org/api", "BranchName": "main" } }]
    },
    {
      "stage": "Build",
      "actions": [{ "name": "Build", "provider": "CodeBuild", "config": { "ProjectName": "api-build" } }]
    },
    {
      "stage": "Deploy",
      "actions": [{ "name": "Deploy", "provider": "CodeDeployToECS", "config": { "ApplicationName": "api-ecs-app", "DeploymentGroupName": "api-prod" } }]
    }
  ]
}
```

`get-pipeline-state`（`--query` で抜粋）:

```json
[
  { "stage": "Source", "status": "Succeeded" },
  { "stage": "Build", "status": "Succeeded" },
  { "stage": "Deploy", "status": "InProgress" }
]
```

## EC2 Image Builder

一覧（`list-*`）は概要だけで、中身は ARN を渡して `get-*` で取る。レシピやコンポーネントは `--owner Self` で自アカウントのものに絞れる。

| 取得したいもの | 一覧 | 詳細 |
|---|---|---|
| イメージパイプライン | `aws imagebuilder list-image-pipelines` | `get-image-pipeline --image-pipeline-arn <arn>` |
| イメージレシピ | `aws imagebuilder list-image-recipes --owner Self` | `get-image-recipe --image-recipe-arn <arn>` |
| コンテナレシピ | `aws imagebuilder list-container-recipes --owner Self` | `get-container-recipe --container-recipe-arn <arn>` |
| コンポーネント | `aws imagebuilder list-components --owner Self` | `get-component --component-build-version-arn <arn>/1` |
| インフラ構成 | `aws imagebuilder list-infrastructure-configurations` | `get-infrastructure-configuration --infrastructure-configuration-arn <arn>` |
| 配布設定 | `aws imagebuilder list-distribution-configurations` | `get-distribution-configuration --distribution-configuration-arn <arn>` |
| 作成されたイメージ | `aws imagebuilder list-images --owner Self` / `list-image-pipeline-images --image-pipeline-arn <arn>` | `get-image --image-build-version-arn <arn>` |
| ライフサイクルポリシー | `aws imagebuilder list-lifecycle-policies` | `get-lifecycle-policy` |

### コマンド例

```bash
for arn in $(aws imagebuilder list-image-pipelines --query 'imagePipelineList[].arn' --output text); do
  aws imagebuilder get-image-pipeline --image-pipeline-arn "$arn" \
    --query 'imagePipeline.{name:name,status:status,recipe:imageRecipeArn,infra:infrastructureConfigurationArn,dist:distributionConfigurationArn,schedule:schedule,tests:imageTestsConfiguration.imageTestsEnabled}'
done

for arn in $(aws imagebuilder list-image-recipes --owner Self --query 'imageRecipeSummaryList[].arn' --output text); do
  aws imagebuilder get-image-recipe --image-recipe-arn "$arn" \
    --query 'imageRecipe.{name:name,version:version,parent:parentImage,components:components[].componentArn,volumes:blockDeviceMappings}'
done

aws imagebuilder list-infrastructure-configurations \
  --query 'infrastructureConfigurationSummaryList[].arn' --output text | tr '\t' '\n' |
while read -r arn; do
  aws imagebuilder get-infrastructure-configuration --infrastructure-configuration-arn "$arn" \
    --query 'infrastructureConfiguration.{name:name,types:instanceTypes,profile:instanceProfileName,subnet:subnetId,sgs:securityGroupIds,terminateOnFail:terminateInstanceOnFailure}'
done
```

### レスポンス例

`list-image-pipelines`（抜粋）:

```json
{
  "requestId": "0abc1234-5678-90de-f123-4567890abcde",
  "imagePipelineList": [
    {
      "arn": "arn:aws:imagebuilder:ap-northeast-1:123456789012:image-pipeline/al2023-base",
      "name": "al2023-base",
      "platform": "Linux",
      "status": "ENABLED",
      "imageRecipeArn": "arn:aws:imagebuilder:ap-northeast-1:123456789012:image-recipe/al2023-base/1.2.0",
      "infrastructureConfigurationArn": "arn:aws:imagebuilder:ap-northeast-1:123456789012:infrastructure-configuration/build-infra",
      "distributionConfigurationArn": "arn:aws:imagebuilder:ap-northeast-1:123456789012:distribution-configuration/share-ami",
      "schedule": { "scheduleExpression": "cron(0 18 ? * sun *)", "pipelineExecutionStartCondition": "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE" }
    }
  ]
}
```

`get-image-recipe`（`--query` で抜粋）:

```json
{
  "name": "al2023-base",
  "version": "1.2.0",
  "parent": "arn:aws:imagebuilder:ap-northeast-1:aws:image/amazon-linux-2023-arm64/x.x.x",
  "components": [
    "arn:aws:imagebuilder:ap-northeast-1:aws:component/update-linux/x.x.x",
    "arn:aws:imagebuilder:ap-northeast-1:123456789012:component/install-cloudwatch-agent/1.0.0"
  ],
  "volumes": [
    { "deviceName": "/dev/xvda", "ebs": { "volumeSize": 30, "volumeType": "gp3", "encrypted": true, "deleteOnTermination": true } }
  ]
}
```

`get-infrastructure-configuration`（`--query` で抜粋）:

```json
{
  "name": "build-infra",
  "types": ["t4g.medium"],
  "profile": "EC2ImageBuilderInstanceProfile",
  "subnet": "subnet-0aaa1111bbbb2222c",
  "sgs": ["sg-0build111aaaa222b"],
  "terminateOnFail": true
}
```
