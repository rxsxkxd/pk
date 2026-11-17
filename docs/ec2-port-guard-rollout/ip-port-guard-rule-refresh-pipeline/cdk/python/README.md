# CDK（Python）の2スタックと YAML 版との比較

[バケット用](rule_buckets_stack.py)と[パイプライン用](list_refresh_stack.py)を、[app.py](app.py)で合成する。**この3ファイルのコードの各行に日本語コメントを付けた**。

既存 YAML を読み込む実装ではない。`Bucket`・`PipelineProject`・`Pipeline` とアクションの L2 を使い、共通設定やリソース間の接続をまとめる。デプロイ時のパラメータ、スクリプト、成果物、承認の有無は [YAML 版](../../cloudformation/README.md)とそろえている。

## 比較結果

この規模で、作成されるリソースや権限を直接見てレビューすることを重視するなら、**CloudFormation YAML を使う方が分かりやすい**。CDK の入力は短くなったが、出力まで含めると YAML に対する可視性の優位は大きくない。環境ごとの組み合わせや共通部品をさらに増やすなら CDK の利点が出る。

2026-11-17 に実際に合成して比較した。以下の定義行数は、YAML に項目別の日本語コメントを追加する前の比較値。空行・当時のコメント込みで、記法や整形の違いにも左右されるため、判断の補助として扱う。説明コメントによる増加は、構成そのものの複雑さとは分けて考える。

| 比較対象 | 手書き YAML | CDK Python |
|---|---:|---:|
| バケット用の定義 | 77行 | 43行 |
| パイプライン用の定義 | 262行 | 125行 |
| CDK の入口 | 不要 | 11行 |
| 合計 | 339行 | 179行 |
| パイプライン側の CloudFormation リソース数 | 7 | 10 |

項目別コメントの追加前の YAML と比較すると、CDK の入力は全体で約47%短くなった。主に、2つのバケットと2つの CodeBuild の共通化、ロールと成果物用権限の自動作成、アクションの接続を L2 に任せた部分で減っている。

| 観点 | YAML 版 | CDK 版・合成結果 |
|---|---|---|
| 更新処理の流れ | ステージと IAM を直接記述する | `add_stage` と `CodeBuildAction` で入力・出力を接続する |
| 共通設定 | バケットや CodeBuild の設定をそれぞれ記述する | 関数にまとめ、差分だけ渡す |
| ルール配布先の権限 | make は取得と列挙、publish は指定環境への書き込み | 同じ範囲をコードで明記する |
| 成果物用バケットの権限 | 使用する操作を明記する | L2 が取得・書き込みに必要なポリシーを付ける。YAML より操作範囲が広い |
| IAM の表示 | 3つのロールのインラインポリシー | 3つのロールと3つの独立したポリシーに展開される |
| 論理 ID | `MakeRole` など、付けた名前がそのまま見える | `MakeProjectRole83D9E71D` など、ハッシュ付きの名前になる |
| デプロイ時の条件 | `Conditions` と `Fn::If` を直接読む | 承認とバケット作成の条件、ログ保存日数、リポジトリ名は一部 L1 に設定を戻す |
| ツール | AWS CLI だけで反映できる | 合成に Python・CDK が必要。合成したテンプレートは AWS CLI でも反映できる |

CDK で自動付与される成果物用バケットの権限には、書き込み側の `s3:DeleteObject*`・タグや保持設定の操作、パイプライン側のバージョン別 ACL 操作なども含まれる。これらは成果物用バケットに対するものであり、ルール配布先の権限は両版とも分離している。不要なテストレポートの自動権限付与は無効にした。

合成結果を YAML に整形して数えると、バケット用は86行、パイプライン用は547行だった。手書き版と出力が完全一致する実装ではない。比較テストは、ビルド仕様・環境変数・ステージ・承認条件・バケットの保持・配布先の権限など、運用に必要な動作を照合する。

## 準備と合成

この `cdk/python/` で実行する。Python 3.10 以降、CDK CLI が対応する Node.js、CDK CLI が必要。

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt

# 2つのテンプレートをローカルで合成する
cdk synth port-guard-rule-buckets port-guard-list-refresh-staging --no-lookups
```

次の2ファイルが `cdk.out/` に出る。

```text
port-guard-rule-buckets.template.json
port-guard-list-refresh-staging.template.json
```

アセットの登録、AWS の情報の検索、bootstrap は使わない。`SourceDirectory` はパイプラインが取得するリポジトリ内の場所であり、CDK を実行するマシンのローカルパスではない。

スタック名だけを変える場合は、コンテキストを使う。

```bash
cdk synth port-guard-rule-buckets port-guard-list-refresh-production \
  -c stackName=port-guard-list-refresh-production --no-lookups
```

`bucketStackName` でバケット用スタック名も変更できる。環境名やバケット名は、合成時のコンテキストではなく、反映時の CloudFormation パラメータで渡す。

## 反映する場合

実際の AWS への反映は未実施。使用するバケット・Git 接続・パラメータは [YAML 版の手順](../../cloudformation/README.md)と同じ。ここでは CDK のコマンドで反映する例を示す。YAML 版と重ねて同じリソースを作らず、使う実装を1つ選ぶ。

```bash
export AWS_REGION=ap-northeast-1
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PROFILE=your-profile

cdk deploy port-guard-rule-buckets --profile "$AWS_PROFILE"
```

既定では成果物用バケットだけを作る。ルール用バケットは作成済みの名前を出力する。異なるアカウントなどでルール用バケットも新規作成するときだけ、`--parameters CreatePublishBucket=true` を指定する。

バケット用の出力から `PIPELINE_BUCKET` と `PUBLISH_BUCKET` を取得する方法は YAML 版の手順と同じ。認可済みの `CONNECTION_ARN`、`REPOSITORY_ID`、`SOURCE_DIRECTORY` と合わせて指定する。

```bash
cdk deploy port-guard-list-refresh-staging --exclusively --profile "$AWS_PROFILE" \
  --parameters EnvironmentName=staging \
  --parameters PipelineBucketName="$PIPELINE_BUCKET" \
  --parameters PublishBucketName="$PUBLISH_BUCKET" \
  --parameters ConnectionArn="$CONNECTION_ARN" \
  --parameters FullRepositoryId="$REPOSITORY_ID" \
  --parameters BranchName=main \
  --parameters SourceDirectory="$SOURCE_DIRECTORY" \
  --parameters RequireApproval=true
```

`--exclusively` は、作成済みのバケット用スタックを再デプロイせず、パイプライン用だけを反映する指定。スタック間の順番は CDK にも記録しているが、バケット名は出力を読んで明示的に渡す。

## 検証

```bash
python -m unittest discover -s tests -v
cfn-lint ../../cloudformation/rule-buckets.yml ../../cloudformation/list-refresh-pipeline.yml
cfn-lint cdk.out/*.template.json --ignore-checks W3005
```

7件のテストで、バケットの新規作成と既存参照・保持設定、承認の有無、両版のビルド仕様、配布先の権限分離を確かめる。シェルのテストでは AWS CLI と curl を模擬し、リージョンとプロファイルの伝達、3環境、前回分の取得、チェックサム、別ディレクトリに渡したビルド成果物だけでのデプロイを実行する。

CDK 合成結果の `W3005` は、CDK が自動付与した `DependsOn` と `GetAtt` の依存が重複している警告なので、この検査では除外する。CDK 内蔵検証も、出力の `Fn::If` 内にある条件付きバケット参照に `W1001` を出す。バケットの有無を選ぶ各分岐はテストで確認し、`cfn-lint` ではこの参照について警告が出ないことを確認した。

実際の AWS での Git 接続・CodeBuild 実行・アップロードは未確認。

使用した AWS の公式資料（2026-11-17）: [S3 の L2](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_s3-readme.html?lang=python)、[CodePipeline の L2](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_codepipeline-readme.html)、[CodePipeline のアクション](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_codepipeline_actions-readme.html?lang=python)。
