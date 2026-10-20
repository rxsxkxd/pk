# RDS の VPC・サブネットグループ・サブネット・SG を AWS CLI で一覧する

`aws rds describe-db-instances` の出力の `DBSubnetGroup` にはサブネット一覧（`Subnets`）も含まれる。そのため 1 コマンドで、全インスタンスの VPC・サブネットグループ・サブネット・SG を取得できる。

```bash
aws rds describe-db-instances \
  --query 'DBInstances[].{ID:DBInstanceIdentifier,Vpc:DBSubnetGroup.VpcId,SubnetGroup:DBSubnetGroup.DBSubnetGroupName,Subnets:join(`,`,DBSubnetGroup.Subnets[].SubnetIdentifier),SGs:join(`,`,VpcSecurityGroups[].VpcSecurityGroupId)}' \
  --output table
```

- `join` を使い、サブネット・SG が複数あっても 1 セルにまとめている。
- サブネットの AZ も見たい場合は `DBSubnetGroup.Subnets[].SubnetAvailabilityZone.Name` を追加する。
- 別環境を見るときは `--profile <名前> --region <リージョン>` を付ける。

## 注意点

- Aurora のインスタンスもこの一覧に含まれ、VPC・サブネットも取れる（`describe-db-clusters` 側には VpcId とサブネットがない）。
- SG は ID のみ。名前が必要なら `aws ec2 describe-security-groups --group-ids <sg-id...> --query 'SecurityGroups[].[GroupId,GroupName]' --output table` で引く。
