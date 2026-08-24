# CDK 導入の判断資料（RDS 構成管理）

> 対象: RDS for MySQL のパラメータグループ、将来的な RDS インスタンス・周辺リソースの IaC 管理
>
> 現時点の決定: 新規 MySQL 8.4 パラメータグループは **CloudFormation YAML のみ**で管理する。CDK の導入は保留する。

## 結論

パラメータグループ 5 個程度を管理する現在のスコープでは、CloudFormation YAML が適している。リソース数と依存関係が小さく、テンプレートのレビューが容易なためである。

将来、RDS インスタンス約 20 台と、その周辺リソースを共通ルールで IaC 管理する段階になった場合は、CDK 導入を再評価する。これは CDK にしか管理できない AWS リソースがあるためではなく、共通構成・環境差分・テストをコードとして再利用しやすくなるためである。

## CloudFormation と CDK の関係

CDK は TypeScript、Python 等で記述した定義から CloudFormation テンプレートを生成する。実際の AWS リソース作成・更新・削除は CloudFormation が実行する。

そのため、通常の RDS、CloudWatch、IAM、Secrets Manager、VPC、Security Group 等に「CDK でしか管理できない」ものは原則ない。CloudFormation が対応しているリソースとプロパティであれば、CDK でも同じ CloudFormation 機能を利用して管理する。

| 観点 | CloudFormation YAML／JSON | CDK |
|---|---|---|
| 定義方法 | 宣言的な YAML／JSON | 汎用プログラミング言語 |
| プロビジョニング実体 | CloudFormation | CloudFormation（CDK がテンプレートを生成） |
| 小規模な構成 | 記述量が少なく、レビューしやすい | 初期設定・依存パッケージが相対的に重い |
| 繰り返し構成 | Parameters、Mappings、Nested Stack 等で実現 | ループ、関数、Construct で自然に共通化できる |
| 入力値の検証 | テンプレート制約、cfn-lint 等 | 型検査、単体テスト、独自バリデーションを追加しやすい |
| 差分確認 | Change Set | `cdk diff` に加え、生成された CloudFormation テンプレートを確認可能 |
| 運用要件 | CloudFormation と YAML の知識 | 左記に加え、選択言語、CDK CLI、依存パッケージの保守が必要 |

## CDK 導入で得られること

CDK の価値は AWS リソースの機能差ではなく、構成をプログラムとして扱えることにある。

### 共通構成の再利用

たとえば標準 RDS 構成を Construct にし、以下を一箇所で定義できる。

- 命名規約、タグ、暗号化、削除保護、バックアップ保持期間
- CloudWatch Logs 出力、CloudWatch Alarm、通知先
- DB パラメータグループ、Security Group、Secrets Manager、IAM ロールの関連付け
- 開発・検証・本番の環境差分と、インスタンスごとの例外値

20 台に同じ必須ルールを適用する場合、各インスタンスは「インスタンスクラス」「用途」「パラメータグループ」「Multi-AZ」等の差分だけを指定できる。

### 依存関係の表現

RDS 構成では、たとえば次の依存関係がある。

```text
VPC / Subnet Group / Security Group
  └─ Secrets Manager の接続情報・IAM 権限
       └─ DB パラメータグループ
            └─ RDS DB インスタンス
                 └─ 監視ログ・CloudWatch Alarm・RDS Proxy
```

CloudFormation でも `Ref`、`Fn::GetAtt`、`DependsOn` で同様に表現できる。CDK はこの関係を Construct 間の参照として記述できるため、多数のリソースや複数環境に広がった際に保守しやすい。

### テストとポリシー適用

CDK では、テンプレートの単体テストや型検査を CI に組み込みやすい。たとえば「すべての本番 DB は暗号化、削除保護、バックアップ 7 日以上、必須タグ、監視アラームを持つ」といった組織ルールを、Construct や Aspect として適用できる。

ただし、同じ統制は CloudFormation のテンプレートレビュー、cfn-lint、CloudFormation Guard、CI の検査でも実現可能である。CDK のみで可能な統制ではない。

## 判断基準

| 状況 | 推奨 |
|---|---|
| パラメータグループ約 5 個のみ | CloudFormation YAML |
| パラメータグループに加え、20 台の RDS を個別設定で管理 | CloudFormation を継続可能。テンプレート分割・レビュー負荷を評価する。 |
| 20 台の RDS に共通ルール、複数環境、監視・IAM・Secrets・ネットワークをまとめて適用 | CDK 導入を再評価する。 |
| 組織が既に CDK を標準採用し、CI／依存パッケージ／レビュー規約が整備済み | CDK を採用するコストは低い。 |
| IaC 対象がパラメータグループだけで、RDS 本体の構築は保留 | CloudFormation YAML のまま進める。 |

## 将来 CloudFormation から CDK へ移行する場合

CloudFormation テンプレートまたは既存スタックを CDK アプリへ移行する仕組みとして `cdk migrate` がある。既存スタックを継続利用する場合は、スタック名と論理 ID を一致させ、CDK が生成したテンプレートとの差分を確認した上で更新する。

移行は比較的進めやすいが、無検証での自動移行はしない。次を必須とする。

1. 現行 CloudFormation テンプレートとスタック情報を保存する。
2. `cdk migrate` またはテンプレート起点で CDK アプリを作成する。
3. `cdk synth` の出力と現行テンプレートを比較する。
4. `cdk diff` と CloudFormation Change Set で、置換・削除・想定外変更がないことを確認する。
5. 同じリソースを CloudFormation YAML と CDK の双方で別々に管理しない。CDK 移行後は、CDK が生成するテンプレートを正本とする。

`cdk migrate` は experimental 扱いであるため、生成コードをレビューしてから利用する。

## 参考

- [AWS CDK と CloudFormation の関係（AWS Prescriptive Guidance）](https://docs.aws.amazon.com/prescriptive-guidance/latest/aws-cdk-layers/layer-1.html)
- [CDK: CloudFormation テンプレート／スタックの移行](https://docs.aws.amazon.com/cdk/v2/guide/migrate.html)
- [AWS::RDS::DBParameterGroup](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-rds-dbparametergroup.html)
