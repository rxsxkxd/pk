# ネットワーク ACL（NACL）を AWS CLI で一覧する

NACL はサブネット単位で効く。各サブネットには NACL が必ず 1 つ関連付けられ、1 つの NACL を複数のサブネットで共有できる。明示的に関連付けていないサブネットには、VPC のデフォルト NACL が適用される。

| | NACL | セキュリティグループ |
|---|---|---|
| 適用先 | サブネット | ENI（RDS などのインスタンス） |
| 状態 | ステートレス（戻りの通信も許可が必要） | ステートフル（戻りの通信は自動で許可） |
| ルール | 許可と拒否、ルール番号の小さい順に評価 | 許可のみ |

RDS への通信は、サブネットグループ内の各サブネットに付いた NACL と、RDS 自身の SG の両方を通る必要がある。

## 全 NACL とルールを一覧する

```bash
aws ec2 describe-network-acls \
  --query 'NetworkAcls[].{NACL:NetworkAclId,Vpc:VpcId,Default:IsDefault,Subnets:Associations[].SubnetId,Rules:Entries[].{No:RuleNumber,Egress:Egress,Action:RuleAction,Proto:Protocol,CIDR:CidrBlock,Ports:PortRange}}'
```

- `Egress` が `false` なら受信ルール、`true` なら送信ルール。
- `Proto` は番号で表される。`6` が TCP、`17` が UDP、`-1` がすべて。
- ルール番号 `32767` は、どのルールにも当てはまらない通信を拒否する既定ルール。

## RDS のサブネットに付いている NACL だけに絞る

```bash
SUBNETS=$(aws rds describe-db-instances \
  --query 'DBInstances[].DBSubnetGroup.Subnets[].SubnetIdentifier' --output text | tr '\t' '\n' | sort -u | paste -sd, -)

aws ec2 describe-network-acls \
  --filters Name=association.subnet-id,Values=$SUBNETS \
  --query 'NetworkAcls[].{NACL:NetworkAclId,Default:IsDefault,Subnets:join(`,`,Associations[].SubnetId)}' \
  --output table
```

ルールも見る場合は、`--query` を上の「全 NACL とルールを一覧する」のものに置き換える。

別環境を見るときは `--profile <名前> --region <リージョン>` を付ける。
