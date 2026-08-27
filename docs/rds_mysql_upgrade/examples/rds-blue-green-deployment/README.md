# RDS Blue/Green Deployment AWS CLI サンプル

Blue/Green Deployment は CloudFormation カスタムリソースを使わず、AWS CLI の RDS API で作成・切替する。CloudFormation は MySQL 8.4 DB パラメータグループの事前作成・管理だけを担当する。

## 設定

環境ごとに 1 ファイルを用意する。例: [`staging.yml`](../../config/blue-green/staging.yml)、[`production.yml`](../../config/blue-green/production.yml)。各ファイルには、その環境に含まれる全サービスについて以下を指定する。

- 移行元 Blue DB の DB インスタンス識別子
- Green DB の MySQL 8.4 バージョンとインスタンスタイプ
- CloudFormation で作成済みの MySQL 8.4 DB パラメータグループ名

パラメータグループは Export 名ではなく、RDS API の `--target-db-parameter-group-name` に渡す実名を設定する。

## Green の作成

```bash
scripts/create_blue_green_deployment.sh \
  --config config/blue-green/staging.yml \
  --service example-service \
  --deployment-name example-service-staging-mysql84-bg-20260827
```

スクリプトは `AVAILABLE` になるまで待機して終了する。応答 JSON は一時ディレクトリに保存される。完了後に Green の接続、レプリケーション、アプリケーション、性能を検証する。

## 切替

検証完了後のみ、作成スクリプトが出力した Deployment 識別子を指定して実行する。

```bash
scripts/switchover_blue_green_deployment.sh \
  --config config/blue-green/staging.yml \
  --blue-green-deployment-id <blue-green-deployment-identifier> \
  --approve
```

`--approve` がない場合、切替操作は実行されない。

`aws_region` は環境設定から取得する。ローカルで名前付きプロファイルを使う場合だけ、コマンドの `--profile` を指定する。GitHub Actions では OIDC で取得した一時認証情報を使用する。

## CI（Step 3〜5）

GitHub Actions の手動ワークフローを使用する。実行ロールは GitHub Environment ごとの `AWS_ROLE_ARN` 変数に設定し、OIDC で引き受ける。

- Step 3: [Build Green](../../.github/workflows/build-green.yml)
- Step 4: [Verify Green](../../.github/workflows/verify-green.yml)
- Step 5: [Switchover Blue Green](../../.github/workflows/switchover.yml)

Step 3 と Step 5 は設定ファイルの `actions.build`／`actions.switchover` が `approved` の場合だけ変更操作を実行する。Step 5 は GitHub Environment の Required reviewers も設定する。

Step 4 の `verify_green.sh` は成果物 `green-verification-report.md` を出力する。このレポートには CloudFormation YAML の宣言値、RDS パラメータグループの `Source=user`／`Source=system`、Green DB へのパラメータグループ関連付け・適用状態、MySQL クライアントが収集した実効値、ReplicaLag を掲載する。YAML と比較バリデーションするのは `Source=user` だけであり、実効値・system 値は人がレビューする。

`verify-green` の `collect_mysql_runtime_values` は既定で `false` である。この場合は Green DB への MySQL 接続を行わず、AWS API による構成・パラメータグループ・レプリカ遅延の確認だけを実行する。`true` を明示して起動した場合だけ、GitHub Environment ごとの Secrets `RDS_MYSQL_USER` と `RDS_MYSQL_PASSWORD` を使用して実効値を収集する。この任意実行には Green DB へネットワーク接続できる GitHub-hosted runner または self-hosted runner が必要である。パスワードは `MYSQL_PASSWORD` として MySQL クライアントの実行プロセスにだけ渡し、コマンド引数・成果物・レポートには出力しない。
