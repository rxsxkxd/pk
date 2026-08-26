# Phase 1 — MySQL 8.4 パラメータグループの CloudFormation 管理

> スコープ: 新規の RDS for MySQL 8.4 用 DB パラメータグループのみ
>
> スコープ外: RDS DB インスタンス、Blue/Green Deployments、RDS Proxy、ネットワーク、スナップショットの作成・変更

## 前提知識: RDS for MySQL の DB パラメータグループ

### パラメータグループとは

RDS for MySQL の DB パラメータグループは、MySQL の動作を構成する値を RDS が管理するためのコンテナである。DB インスタンスは必ず 1 つの DB パラメータグループを使用する。作成時に指定しなければ、RDS はエンジンとバージョンに対応するデフォルトグループを関連付ける。

パラメータグループには、対象の MySQL ファミリーで **RDS が公開している**パラメータの一覧と、その解決済みの値が存在する。ただし、これは MySQL が内部に持つあらゆる設定を自由に操作できるという意味ではない。RDS が変更不可としている値、RDS がシステム側で決める値、RDS で公開されない MySQL 設定は変更できない。

`describe-db-parameters` の `Source` は、値の由来を示す。

| `Source` | 意味 |
|---|---|
| `engine-default` | MySQL エンジンファミリーのデフォルト値。 |
| `system` | RDS がインスタンスクラス、ストレージ等から決定するシステム値。 |
| `user` | カスタムパラメータグループで明示的に上書きした値。 |

### すべての値を定義する必要はない

いいえ。カスタムパラメータグループを作成しても、全パラメータを CloudFormation の `Parameters` へ列挙する必要はないし、列挙すべきでもない。新しいカスタムグループは対応するエンジンファミリーのデフォルト値を基礎とし、`Parameters` にはデフォルトから変更したい値だけを宣言する。

テンプレートに設定がないパラメータは未設定のままではなく、RDS の engine default または system 値が適用される。このため、CloudFormation の `Parameters` は「有効な全 MySQL 設定の完全な写し」ではなく、「IaC として意図的に上書きする差分」の一覧として扱う。

カスタムグループが必要なのは、RDS が変更を許可するパラメータを既定値から変更したい場合である。本移行では MySQL 8.4 用の `mysql8.4` ファミリーの新規グループが必要になる。`binlog_format=ROW` は Blue/Green の成立条件ではないが、8.4 の既定値であり、設定意図を固定したい場合は CloudFormation に明示できる。既定値のままでよい場合は、デフォルトパラメータグループの利用も可能である。ただしデフォルトグループ自体は変更できない。

### MySQL 8.0 と 8.4 の差異をどう扱うか

DB パラメータグループは 1 つのファミリーにのみ属し、互換性のあるエンジン／バージョンでだけ使える。そのため `mysql8.0` のグループを `mysql8.4` に転用・変換することはできない。8.4 用には `Family: mysql8.4` の新規グループを作る。

バージョン差異は次の手順で吸収する。8.0 のグループ全体をコピーせず、明示設定だけを 8.4 の公開パラメータ・許容値・**engine default** と突き合わせる。RDS が返す `Source=system` の値は、インスタンス構成に依存する別の値として扱う。

1. `describe-db-parameters --source user` で、現行 `mysql8.0` グループの上書き値を採取する。
2. `describe-db-parameters --source system` で現行 8.0 グループの値の由来が RDS system であるパラメータを、`describe-engine-default-parameters --db-parameter-group-family mysql8.0` と `mysql8.4` で各ファミリーの engine default を取得する。これらを区別したうえで、対象パラメータの存在、値、`AllowedValues`、`ApplyType`、`IsModifiable` を比較する。
3. 各値を「8.4 へ移植」「8.4 の既定値を採用」「代替パラメータへ変更」「除外」に分類し、理由をレビューする。
4. 「移植」または「代替」と判断した値だけを `mysql8.4` の CloudFormation `Parameters` に記載する。
5. 作成後に `describe-db-parameters` で `Source=user`、値、`ApplyType` を検証する。静的パラメータの影響は、後続で DB に関連付ける際に評価する。

この方式により、8.4 で廃止されたパラメータ、許容値が変わったパラメータ、8.4 の改善された既定値を盲目的に 8.0 の値で上書きすることを防ぐ。

### 8.4 の既定値・インスタンス依存値を固定しない理由

移行レポートの「RDS・インスタンスクラス依存の自動算出」「CPU・メモリ依存の既定値または算出方式」「エンジン既定値・挙動変更」という分類は、`Source` が必ず `system` であることを示すものではない。8.4 での値の決まり方と、8.0 の固定値を CloudFormation で再設定するリスクを示すレビュー分類である。

- `innodb_buffer_pool_size`、`innodb_redo_log_capacity`、`innodb_dedicated_server` は、8.4 では `innodb_dedicated_server` が既定で有効になり、DB インスタンスクラスのメモリ・vCPU を基にエンジンが算出する。RDS は小さいインスタンスクラスで実効値を調整することもあるため、単純な固定既定値ではなく、実質的にインスタンス依存の値である。8.0 の明示値をそのまま CloudFormation に移植せず、Green のインスタンスクラスで算出結果、メモリ使用量、ストレージ容量を確認する。 [AWS: MySQL 8.4 のバッファプールと redo ログ容量](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.CommonDBATasks.Config.Size.8.4.html)
- `innodb_purge_threads`、`innodb_buffer_pool_instances`、`innodb_parallel_read_threads` などは、8.4 の既定値または算出方式が CPU・メモリ等に依存するためレビューする。`innodb_purge_threads` は RDS で vCPU に基づく式が既定値である。 [AWS: RDS for MySQL 8.4 の機能差分](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html)
- `innodb_change_buffering`、`innodb_io_capacity`、Group Replication 系などは、主にエンジン既定値または挙動が変わる対象であり、RDS の `system` 値とは限らない。性能・整合性・障害時の挙動を Green で確認してから、8.4 の既定値を採用するか明示設定するかを決める。

Phase 1 の時点では DB インスタンスにまだ関連付けないため、実効値は確定しない。関連付け後の後続フェーズで `describe-db-parameters` の `Source` と、DB 接続後の `@@innodb_buffer_pool_size` などの実効値を照合する。

## 方針

- 既存の MySQL 8.0 パラメータグループは AWS CLI で**読み取りのみ**行う。
- 新規の MySQL 8.4 パラメータグループは CloudFormation スタックを唯一の変更経路とする。
- 8.0 の設定値を機械的に複製せず、8.4 での有効性をレビューした値だけをテンプレートに宣言する。
- 本フェーズでは DB パラメータグループを作成するだけであり、DB インスタンスへ関連付けない。したがって DB の再起動や接続影響は発生しない。

## フロー

```text
現行 8.0 パラメータグループ
  └─ AWS CLI（read-only）で Source=user の値を採取
       └─ 8.4 互換性レビュー・移植方針の決定
            └─ CloudFormation テンプレートの Parameters に明示
                 └─ Change Set のレビュー・承認
                      └─ CloudFormation で mysql8.4 パラメータグループを作成／更新
                           └─ AWS CLI（read-only）で作成結果を照合
```

## 1. 現行 8.0 のユーザー設定値を採取する

対象の DB パラメータグループ名は Phase 0 の収集結果から取得する。次の AWS CLI は読み取り専用であり、`Source=user` のパラメータだけを取得する。

### 自動生成フロー（推奨）

以下のスクリプトは、AWS CLI の読み取り API による収集と、Ruby によるローカル判定・YAML 生成を分離している。`Source=user` の値は、8.4 に同名または移行ルール上の対応先が存在し変更可能であれば YAML へ明示する。8.4 で廃止され保留とした値、存在しない値、変更不可の値は YAML に出力せず「生成不可」または「設定対象外」とする。

```bash
# 1. 現行の user／system 値、8.0／8.4 の engine default、任意で関連付け状態を一時ディレクトリへ収集する
bash scripts/collect_mysql84_parameter_inputs.sh \
  --source-parameter-group <current-mysql80-parameter-group> \
  --db-instance-id <blue-instance-id> \
  --region <region> \
  --profile <profile>

# 2. ルールベースで比較し、レビュー報告と CloudFormation YAML を生成する
ruby scripts/generate_mysql84_parameter_group.rb \
  --input-dir <collector-output-dir> \
  --output-dir <generated-dir> \
  --system <system> \
  --environment <environment>
```

生成時に使用するルールは [mysql80-to-84-parameter-rules.yml](config/mysql80-to-84-parameter-rules.yml) で管理する。出力は次の 2 ファイルである。

- `mysql80-to-mysql84-parameter-report.md`: 8.0 の `Source=user`・`Source=system`・8.0／8.4 の engine default・ルール・生成可否を区別して一覧化したレビュー報告
- `mysql84-parameter-group.yaml`: `AWS::RDS::DBParameterGroup` のみを含む CloudFormation テンプレート

「要レビュー」または「生成不可」が残る場合、Ruby スクリプトは終了コード `1` を返す。ルールを追加・修正し、該当値の互換性と意図をレビューしてから再生成する。`default_authentication_plugin=mysql_native_password` の user 定義は `authentication_policy: "*:mysql_native_password"` へ変換する。この値は `mysql_native_password` を第1認証要素の既定にしつつ他方式も許可する。Green では既存アカウントとクライアントの接続試験を必須とする。

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name <current-mysql80-parameter-group> \
  --source user \
  --output json > current-mysql80-user-parameters.json
```

採取結果を次のいずれかに分類し、レビュー記録を残す。

| 分類 | 扱い |
|---|---|
| 移植 | 8.4 でも有効かつ意図どおりの値。CloudFormation テンプレートへ記載する。 |
| 8.4 既定値を採用 | 8.0 での明示値を引き継がず、8.4 のデフォルトを使う。テンプレートへ記載しない。 |
| 代替設定 | 廃止・名称変更・挙動変更がある。代替パラメータと判断理由を記録する。 |
| 除外 | DB インスタンス固有、または本移行では不要。理由を記録する。 |

## 2. CloudFormation テンプレートへ宣言する

`AWS::RDS::DBParameterGroup` だけを含む専用スタックにする。DB インスタンスを表す `AWS::RDS::DBInstance` や `AWS::RDS::BlueGreenDeployment` は、このテンプレートへ追加しない。

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: MySQL 8.4 DB parameter group only

Resources:
  Mysql84ParameterGroup:
    Type: AWS::RDS::DBParameterGroup
    Properties:
      DBParameterGroupName: <system>-<environment>-mysql84-v1
      Description: MySQL 8.4 parameters for <system>/<environment>
      Family: mysql8.4
      Parameters:
        binlog_format: ROW
        # Phase 1 のレビューで「移植」と判定した値だけを列挙する。
        # max_allowed_packet: 67108864
      Tags:
        - Key: System
          Value: <system>
        - Key: Environment
          Value: <environment>
        - Key: ManagedBy
          Value: CloudFormation

Outputs:
  DBParameterGroupName:
    Description: Name of the MySQL 8.4 DB parameter group
    Value: !Ref Mysql84ParameterGroup
```

`Family` は `mysql8.4` とする。`DBParameterGroupName`、`Description`、`Family` の変更は置換になるため、名前は `...-v1` のように世代を含める。設定を大きく変更する場合は `v2` を新規作成し、後続フェーズで関連付け先を切り替える。

> CloudFormation ではパラメータごとの `ApplyMethod` を指定できず、RDS の既定の適用方式が使われる。静的パラメータの影響は、後続で DB に関連付ける際に別途評価する。

## 3. Change Set でレビューしてから適用する

テンプレートをリポジトリで管理し、Pull Request と Change Set の両方を承認対象にする。

```bash
# 作成予定の差分を確認する。DB インスタンスは変更対象に含まれないことを確認する。
aws cloudformation create-change-set \
  --stack-name <system>-<environment>-mysql84-parameter-group \
  --change-set-name <change-set-name> \
  --change-set-type CREATE \
  --template-body file://<template-file>.yaml
```

レビュー観点は次のとおり。

- リソースが `AWS::RDS::DBParameterGroup` だけであること。
- `Family: mysql8.4`、タグ、名前の世代が正しいこと。
- `Parameters` が採取結果・移植判断表と一致すること。
- 意図しない置換や削除がないこと。

承認後に Change Set を実行する。通常の作業者には `rds:ModifyDBParameterGroup` を許可せず、CloudFormation 実行ロールだけに許可する。

## 4. 作成後に AWS CLI で読み取り検証する

CloudFormation スタックの出力からパラメータグループ名を取得し、宣言値と RDS の実値を照合する。以下も読み取り操作のみである。

```bash
aws cloudformation describe-stacks \
  --stack-name <system>-<environment>-mysql84-parameter-group \
  --query "Stacks[0].Outputs[?OutputKey=='DBParameterGroupName'].OutputValue" \
  --output text

aws rds describe-db-parameters \
  --db-parameter-group-name <new-mysql84-parameter-group> \
  --source user \
  --query 'Parameters[].[ParameterName,ParameterValue,ApplyType,ApplyMethod,Source]' \
  --output table
```

確認結果、CloudFormation のスタック ID、Change Set 名、テンプレートのコミット ID を証跡に残す。

## 完了条件

- [ ] 現行 8.0 の `Source=user` パラメータを AWS CLI で取得・保存した。
- [ ] 各設定値の 8.4 への移植判断をレビュー済みである。
- [ ] `AWS::RDS::DBParameterGroup` のみを含む CloudFormation テンプレートを承認済みである。
- [ ] Change Set で RDS DB インスタンスの作成・変更が含まれないことを確認した。
- [ ] `mysql8.4` の新規パラメータグループを CloudFormation で作成し、AWS CLI で宣言値と照合した。
- [ ] DB インスタンスへの関連付けは未実施であり、後続フェーズの作業として保留している。

## 参考

- [AWS::RDS::DBParameterGroup](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-rds-dbparametergroup.html)
- [RDS のパラメータグループの概要](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/parameter-groups-overview.html)
- [RDS for MySQL で利用可能なパラメータ](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.Parameters.html)
- [AWS CLI: describe-db-parameters](https://docs.aws.amazon.com/cli/latest/reference/rds/describe-db-parameters.html)
- [AWS CLI: describe-engine-default-parameters](https://docs.aws.amazon.com/cli/latest/reference/rds/describe-engine-default-parameters.html)
