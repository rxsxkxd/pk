# CDK（Python）のパイプライン用スタックと YAML 版との比較

[パイプライン用](list_refresh_stack.py)と[ルールのデプロイ先バケット用](rule_deploy_bucket_stack.py)（作り方の記録。このアカウントでは流さない）を、[app.py](app.py)で合成する。2 つのスタックの間に依存はない。コードは部品ごとのメソッドに分け、説明は各部品の頭のコメントにまとめた（2026-11-18 に、行ごとの末尾のコメントをやめた）。スタックはパイプライン用の 1 種類だけで、パイプラインの受け渡しバケットもこの中で作る。ルールのデプロイ先バケットは先に手で作ったものを名前で参照し、作らない（2026-11-18 に、バケット用スタックを無くした）。

既存 YAML を読み込む実装ではない。`Bucket`・`PipelineProject`・`Pipeline` とアクションの L2 を使い、共通設定やリソース間の接続をまとめる。デプロイ時のパラメータ、スクリプト、成果物、承認の有無は [YAML 版](../../cloudformation/README.md)とそろえている。

## 比較結果

この規模で、作成されるリソースや権限を直接見てレビューすることを重視するなら、**CloudFormation YAML を使う方が分かりやすい**。CDK の入力は短くなったが、出力まで含めると YAML に対する可視性の優位は大きくない。環境ごとの組み合わせや共通部品をさらに増やすなら CDK の利点が出る。

2026-11-17 に実際に合成して比較した（バケット用スタックがあった時点の値）。以下の定義行数は、YAML に項目別の日本語コメントを追加する前の比較値。空行・当時のコメント込みで、記法や整形の違いにも左右されるため、判断の補助として扱う。説明コメントによる増加は、構成そのものの複雑さとは分けて考える。

| 比較対象 | 手書き YAML | CDK Python |
|---|---:|---:|
| バケット用の定義 | 77行 | 43行 |
| パイプライン用の定義 | 262行 | 125行 |
| CDK の入口 | 不要 | 11行 |
| 合計 | 339行 | 179行 |
| パイプライン側の CloudFormation リソース数 | 7 | 10 |

項目別コメントの追加前の YAML と比較すると、CDK の入力は全体で約47%短くなった。主に、2つのバケットと2つの CodeBuild の共通化、ロールとパイプラインの受け渡しバケットの権限の自動作成、アクションの接続を L2 に任せた部分で減っている。

| 観点 | YAML 版 | CDK 版・合成結果 |
|---|---|---|
| 更新処理の流れ | ステージと IAM を直接記述する | `add_stage` と `CodeBuildAction` で入力・出力を接続する |
| 共通設定 | バケットや CodeBuild の設定をそれぞれ記述する | 関数にまとめ、差分だけ渡す |
| ルールのデプロイ先の権限 | make は取得と列挙、publish は指定環境への書き込み | 同じ範囲をコードで明記する |
| パイプラインの受け渡しバケットの権限 | 使用する操作を明記する | L2 が取得・書き込みに必要なポリシーを付ける。YAML より操作範囲が広い |
| IAM の表示 | 3つのロールのインラインポリシー | 3つのロールと3つの独立したポリシーに展開される |
| 論理 ID | `MakeRole` など、付けた名前がそのまま見える | `MakeProjectRole83D9E71D` など、ハッシュ付きの名前になる |
| デプロイ時の条件 | `Conditions` と `Fn::If` を直接読む | 承認とバケット作成の条件、ログ保存日数、リポジトリ名は一部 L1 に設定を戻す |
| ルールジェネレーターのリポジトリのホスト | デプロイ時のパラメータ `SourceProvider` で GitHub か CodeCommit を選ぶ。1 つのテンプレートで両方を持つ | **合成時**のコンテキスト `sourceProvider` で選ぶ。選んだホストの L2 のアクションと権限だけが入り、パラメータも選んだ方の分だけになる |
| ツール | AWS CLI だけで反映できる | 合成に Python・CDK が必要。合成したテンプレートは AWS CLI でも反映できる |

CDK で自動付与されるパイプラインの受け渡しバケットの権限には、書き込み側の `s3:DeleteObject*`・タグや保持設定の操作、パイプライン側のバージョン別 ACL 操作なども含まれる。これらはパイプラインの受け渡しバケットに対するものであり、ルールのデプロイ先の権限は両版とも分離している。不要なテストレポートの自動権限付与は無効にした。

合成結果を YAML に整形して数えると、バケット用は86行、パイプライン用は547行だった。手書き版と出力が完全一致する実装ではない。比較テストは、ビルド仕様・環境変数・ステージ・承認条件・バケットの保持・ルールのデプロイ先の権限など、運用に必要な動作を照合する。

## 準備と合成

この `cdk/python/` で実行する。Python 3.10 以降、CDK CLI が対応する Node.js、CDK CLI が必要。

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt

# テンプレートをローカルで合成する
cdk synth port-guard-list-refresh-staging --no-lookups
```

`cdk.out/port-guard-list-refresh-staging.template.json`（パイプライン用）と `cdk.out/port-guard-rule-deploy-bucket.template.json`（ルールのデプロイ先バケット用。流さない）に出る。

アセットの登録、AWS の情報の検索、bootstrap は使わない。`SourceDirectory` はパイプラインが取得するリポジトリ内の場所であり、CDK を実行するマシンのローカルパスではない。

スタック名だけを変える場合は、コンテキストを使う。

```bash
cdk synth port-guard-list-refresh-production \
  -c stackName=port-guard-list-refresh-production --no-lookups
```

環境名やルールのデプロイ先バケットの名前は、合成時のコンテキストではなく、反映時の CloudFormation パラメータで渡す。

ルールジェネレーターのリポジトリのホストは、合成時のコンテキスト `sourceProvider` で選ぶ（既定は `GitHub`）。YAML 版と違い、反映時のパラメータでは切り替えない。L2 の `CodeStarConnectionsSourceAction` と `CodeCommitSourceAction` を、それぞれの権限の自動付与ごとそのまま使うため。

```bash
# CodeCommit のリポジトリから取るパイプラインを合成する
cdk synth port-guard-list-refresh-staging -c sourceProvider=CodeCommit --no-lookups
```

| `sourceProvider` | 反映時に渡すパラメータ | パイプラインのロールに付く権限 |
|---|---|---|
| `GitHub` | `ConnectionArn`・`FullRepositoryId` | その接続の `UseConnection` |
| `CodeCommit` | `CodeCommitRepositoryName` | そのリポジトリの `codecommit:GetBranch` など（L2 が付ける） |

## 反映する場合

実際の AWS への反映は未実施。使用するバケット・ルールジェネレーターのリポジトリ・パラメータは [YAML 版の手順](../../cloudformation/README.md)と同じ（`SourceProvider` だけは渡さず、合成時に選ぶ）。ここでは CDK のコマンドで反映する例を示す。YAML 版と重ねて同じリソースを作らず、使う実装を1つ選ぶ。

```bash
export AWS_REGION=ap-northeast-1
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PROFILE=your-profile
```

パイプラインの受け渡しバケットはスタックが作るので、渡すものはない。ルールのデプロイ先バケットは、手で作ったものの名前の先頭部分が既定の `ip-port-guard-rules` と違うときだけ `RuleDeployBucketNamePrefix` で渡す。ルールジェネレーターのリポジトリの指定と `SOURCE_DIRECTORY` と合わせて指定する。

```bash
# GitHub のとき（認可済みの接続）
cdk deploy port-guard-list-refresh-staging --profile "$AWS_PROFILE" \
  --parameters EnvironmentName=staging \
  --parameters ConnectionArn="$CONNECTION_ARN" \
  --parameters FullRepositoryId="$REPOSITORY_ID" \
  --parameters BranchName=main \
  --parameters SourceDirectory="$SOURCE_DIRECTORY"

# CodeCommit のとき（合成時と同じ -c sourceProvider=CodeCommit を付ける）
cdk deploy port-guard-list-refresh-staging --profile "$AWS_PROFILE" -c sourceProvider=CodeCommit \
  --parameters EnvironmentName=staging \
  --parameters CodeCommitRepositoryName="$CODECOMMIT_REPOSITORY" \
  --parameters BranchName=main \
  --parameters SourceDirectory="$SOURCE_DIRECTORY"
```


## 検証

```bash
python -m unittest discover -s tests -v
cfn-lint ../../cloudformation/list-refresh-pipeline.yml ../../cloudformation/rule-deploy-bucket.yml
cfn-lint cdk.out/*.template.json --ignore-checks W3005
```

テストで、ルールのデプロイ先バケットの作成と参照・保持設定、承認の有無、両版のビルド仕様、ルールのデプロイ先の権限分離を確かめる。ルールジェネレーターのリポジトリは GitHub と CodeCommit の両方で、YAML 版（`SourceProvider` で切り替え）と CDK 版（合成時に切り替え）の Source のステージ・パイプラインのロールの権限・パラメータを照合する（2026-11-18 に追加。定期実行・通知・ルールのデプロイ先バケットの照合も含めて 14 件すべて通った）。シェルのテストでは AWS CLI と curl を模擬し、リージョンとプロファイルの伝達、3環境、前回分の取得、チェックサム、別ディレクトリに渡したビルド成果物だけでのデプロイを実行する。

CDK 合成結果の `W3005` は、CDK が自動付与した `DependsOn` と `GetAtt` の依存が重複している警告なので、この検査では除外する。

実際の AWS での CodeConnections 接続・CodeCommit からの取得・CodeBuild 実行・アップロードは未確認。

使用した AWS の公式資料（2026-11-17）: [S3 の L2](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_s3-readme.html?lang=python)、[CodePipeline の L2](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_codepipeline-readme.html)、[CodePipeline のアクション](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_codepipeline_actions-readme.html?lang=python)。2026-11-18 に追加: [CodeCommit のソースアクション](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodeCommit.html)。
