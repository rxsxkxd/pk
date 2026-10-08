# release-verification — 前段: 作成元のインスタンスでのテスト（フェーズ 3）

> 状態: **未実装**（開発の優先順位はフェーズ 3。後段のフェーズ 2 の後に着手する）。このフォルダには役割と設計への参照だけを置いている。全体の中での位置付けは [全体像](../README.md#全体像) を参照。

## 役割

常時起動のリリース用 EC2 インスタンスに、リリースバージョン（例: `v1.2.3`）を配置し、テストを通してアプリを起動した状態にする。この状態のインスタンスから、中段の [`ami-publish/`](../ami-publish/README.md) が AMI を作る。

1. リリースタグをチェックアウトする（`releases/<version>` に配置し、`current` のシンボリックリンクで切り替える）
2. `bundle install`
3. RSpec（テスト専用の DB に接続する。本番 DB には接続しない）
4. 任意: E2E
5. アセットのプリコンパイル、アプリの切り替えと再起動
6. ヘルスチェック（失敗したら直前のリリースに戻す）
7. AMI 作成前の後片付け（ログ、テストの成果物、デプロイキーなど）

## 現状

担当者が手作業で行い、完了後に AMI 公開パイプラインを起動する（`aws codepipeline start-pipeline-execution --variables name=VERSION,value=vX.Y.Z`）。

## 将来（フェーズ 3）

リリース検証パイプラインとして自動化する構想。SSM ドキュメントでインスタンス上のリリース処理を実行し、成功したら AMI 公開パイプラインを同じ起動コマンドで起動する。

## 関連ドキュメント

- [リリース検証の設計（リリーススクリプト、ディレクトリ構成、DB と設定の分離）](../ami-build-pipeline.md)
- [メモ: CodeBuild での E2E テストの構成](../notes/release-verification/e2e-testing-on-codebuild-memo.md)
