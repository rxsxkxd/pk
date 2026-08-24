# AWS リソースの棚卸しツール

AWS アカウントの 1 リージョンにあるリソースを一覧にし、1 件 1 行の JSON（JSONL）で出力するツール群。OS やランタイムの更新計画、設定の点検、どこから呼ばれているかの調査に使う。

| フォルダ | 対象 | 1 行の単位 | 主にわかること |
|---|---|---|---|
| [`lambda-inventory/`](./lambda-inventory/README.md) | Lambda | 関数 | ランタイムとベース OS、設定、トリガー（ポリシーとイベントソースマッピング） |
| [`ec2-inventory/`](./ec2-inventory/README.md) | EC2 | インスタンス | ベース OS（SSM の報告か AMI 名から）、AMI、IMDS、SSM の状態、ネットワーク |
| [`ecs-inventory/`](./ecs-inventory/README.md) | ECS | サービス / コンテナインスタンス | タスク定義・イメージ・OS・アーキテクチャ、ロードバランサー、ホストのエージェントと AMI |
| [`compute-inventory/`](./compute-inventory/README.md) | EC2 + ECS + CodeBuild | インスタンス / サービス / プロジェクト | 一覧（`snapshot`）と、絞り込んだ対象の詳細（`detail`）の 2 段階。数百台の環境向け。**作成中**で、できたら `ec2-inventory/` と `ecs-inventory/` を置き換える |

## 共通の方針

- **実装は 3 つ。** どのツールにも、シェル（AWS CLI + jq）・Ruby（AWS SDK for Ruby）・Python（boto3）の実装があり、同じ入力から同じ形の JSONL を出す。
- **読み取りだけ。** List / Describe / Get 系の API しか呼ばない。
- **API の呼び出しを少なくする。** まとめて取得できる API はまとめて呼び、リソースごとの呼び出しは避けられないものだけにしている。出力の項目は、呼んでいる API の応答から作れるものに限っている。
- **秘密情報は出さない。** 環境変数やシークレットの値は出さない（Lambda だけ、環境変数の名前を出す）。
- **失敗は黙って捨てない。** 個々のリソースの取得に失敗したものは、そのレコードの `errors` に `{operation, code, message}` として残す。一覧の取得そのものが失敗したときは、結果が不完全になるので途中で止まる。
- **対象は AWS の標準の設定で決まる。** `AWS_PROFILE` と `AWS_REGION` で、アカウントとリージョンを選ぶ。複数のリージョンを調べるときは、リージョンを変えて繰り返し実行する。

## 組み合わせて使う

ECS のコンテナインスタンスは EC2 インスタンスでもあるので、`ec2_instance_id` で EC2 の棚卸しの結果と突き合わせると、ホストのベース OS がわかる。手順は [`ecs-inventory/README.md`](./ecs-inventory/README.md) の絞り込みの例を参照。
