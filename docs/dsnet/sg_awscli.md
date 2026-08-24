# セキュリティグループとルールを AWS CLI で一覧する

全 SG をルールごと取得するには、フィルタなしの `aws ec2 describe-security-groups` を使う。受信ルールは `IpPermissions`、送信ルールは `IpPermissionsEgress` に入る。

```bash
aws ec2 describe-security-groups \
  --query 'SecurityGroups[].{SG:GroupId,Name:GroupName,Vpc:VpcId,Inbound:IpPermissions,Outbound:IpPermissionsEgress}'
```

ルールはネストした形式なので、`--output table` にすると見づらい。

## ルールを 1 行ずつ表で出す

`describe-security-group-rules` は全ルールを 1 行に 1 つずつ返す。

```bash
aws ec2 describe-security-group-rules \
  --query 'SecurityGroupRules[].{SG:GroupId,Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,SrcSG:ReferencedGroupInfo.GroupId,Desc:Description}' \
  --output table
```

- `Egress` が `False` なら受信ルール、`True` なら送信ルール。
- 接続元が SG のルールは、`SrcSG` に接続元の SG ID が入る。
- `Proto` が `-1` なら全プロトコル。
- 出力に SG 名と VPC は含まれない。必要なら `describe-security-groups` の結果と SG ID で突き合わせる。

## RDS が使っている SG だけに絞る

```bash
SGS=$(aws rds describe-db-instances \
  --query 'DBInstances[].VpcSecurityGroups[].VpcSecurityGroupId' --output text | tr '\t' '\n' | sort -u | paste -sd, -)

aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values=$SGS \
  --query 'SecurityGroupRules[].{SG:GroupId,Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,SrcSG:ReferencedGroupInfo.GroupId}' \
  --output table
```

別環境を見るときは `--profile <名前> --region <リージョン>` を付ける。
