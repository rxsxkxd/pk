# トラブルシューティング: AMI 公開パイプライン

> スコープ: [`ami-publish/`](./ami-publish/README.md) の AMI 公開パイプラインが失敗した・止まって見えるときの、原因の切り分けと対処
>
> 関連: [確認手順書: 稼働環境での確認](./ami-publish-environment-verification.md) / [開発計画](./ami-publish-development-plan.md)

## まず見るところ

### どこで失敗したか

CodeBuild のログ（CloudWatch Logs `/<application_name>/<環境>/ami-publish`、ストリーム `codebuild/...`）に、AMI 公開ツールの JSON 形式のログが出る。

| ログ | 意味 |
|---|---|
| `{"event":"step_started","step":"..."}` | そのステップを開始した |
| `{"event":"waiting",...}` | 待機中の進捗（`progress_log_interval_seconds` ごと）。項目で何を待っているかがわかる |
| `{"event":"step_failed","step":"...","message":"..."}` | そのステップで失敗した。`message` が原因 |
| `{"event":"image_deleted",...}` | 失敗時の後始末で AMI とスナップショットを削除した |
| `{"event":"published",...}` | 成功 |

`step_started` の後に `step_failed` も `step_finished` も出ていなければ、そのステップの途中で止まっている（または CodeBuild のタイムアウトで強制終了された）。

### 終了コード

CodeBuild の `Command did not exit successfully bin/ami_publish run ... exit status N` の `N`:

| 終了コード | 意味 | 見るところ |
|---|---|---|
| 1 | ステップが望ましい状態に到達できなかった（AMI の作成失敗、SSM に接続できない、ヘルスチェック失敗、想定外の差分など） | `step_failed` の `message` |
| 2 | 使い方・設定値の誤り（`VERSION` 未指定、形式の誤り、設定値ファイルの誤り） | ログの先頭の `エラー:` の行 |
| 3 | AWS のエラー（権限不足、認証情報なし、接続できない） | `aws_error` の `error_class` と `message` |

### 失敗したときに AWS がどうなっているか

| 失敗したステップ | AMI | 起動テンプレート | リリース用インスタンス |
|---|---|---|---|
| 0 状態・SSM の確認 | 作っていない | 変更なし | 変更なし |
| 1 AMI の作成 | 作っていない | 変更なし | 変更なし |
| 2 AMI の完成待ち / 2a インスタンスの起動 / 3 SSM の接続待ち / 4 ヘルスチェック | 削除済み | 変更なし | 起動中なら再起動済み。停止中だった場合は起動したまま |
| 5 起動テンプレートのスタックの更新 | **残っている**（同じ実行の再試行で再利用する） | 変更なし（スタックはロールバック） | 同上 |
| CodeBuild のタイムアウトで強制終了 | 後始末が動かないため残っていることがある | 変更なし | 同上 |

## 症状別の索引

| 症状 | 節 |
|---|---|
| `ping_status` が「SSM に未登録」のまま / 「SSM の管理対象になっていない」 | [1](#1-ssm-の管理対象になっていない) |
| `ping_status` が `ConnectionLost` のまま / 「SSM Agent が接続していない」 | [2](#2-ssm-agent-が接続しない) |
| ステップ 4 で `ヘルスチェックが失敗した` | [3](#3-ヘルスチェックが失敗する) |
| ステップ 2 で長時間待つ / `available にならなかった` / 60 分で強制終了 | [4](#4-ami-の作成が終わらない失敗する) |
| ステップ 2a で `起動できなかった` | [5](#5-停止中のインスタンスを起動できない) |
| ステップ 5 で `起動テンプレート以外の変更が含まれているため中止した` / `更新できる状態ではない` | [6](#6-起動テンプレートのスタックを更新できない) |
| install フェーズで失敗する（Ruby、`bundle install`、buildspec が見つからない） | [7](#7-codebuild-の-install-フェーズで失敗する) |
| 終了コード 2 で止まる | [8](#8-終了コード-2使い方設定値の誤り) |
| 終了コード 3 で止まる | [9](#9-終了コード-3aws-のエラー) |
| `rollback` で `見つからない` / `複数ある` | [10](#10-rollback-が失敗する) |
| 手元のテストで `linked to incompatible libruby` | [11](#11-手元での問題) |

## 1. SSM の管理対象になっていない

**症状**: ステップ 0（または 3）の進捗ログの `ping_status` が `（SSM に未登録）` のまま。ステップ 0 で「SSM の管理対象になっていない（Fleet Manager に表示されない）。AMI は作成していない」で失敗する。

**意味**: SSM の管理対象の一覧に、リリース用インスタンスが存在しない。一度でも接続したことのあるインスタンスは、切断中でも `ConnectionLost` として一覧に残るため、「未登録」は**そもそも SSM の管理対象になっていない**ことを示す。CodeBuild の権限不足ではない（権限不足なら終了コード 3 になる）。

**確認**:

```bash
# SSM から見えているか（null なら管理対象になっていない）
aws ssm describe-instance-information --filters Key=InstanceIds,Values=<インスタンス ID> \
  --query 'InstanceInformationList[0].[PingStatus,LastPingDateTime]'

# インスタンスプロファイルが付いているか
aws ec2 describe-instances --instance-ids <インスタンス ID> \
  --query 'Reservations[0].Instances[0].[IamInstanceProfile.Arn,SubnetId,MetadataOptions.HttpEndpoint]'
```

**原因と対処**（どれかが欠けている）:

| 条件 | 確認・対処 |
|---|---|
| インスタンスプロファイル（IAM ロール）が付いていて、`AmazonSSMManagedInstanceCore` がある | ロールのポリシーを確認し、なければ付与する。**付与・変更した後は SSM Agent を再起動する**（すぐには反映されないことがある） |
| SSM Agent が入っていて、起動している・自動起動が有効 | Amazon Linux: `sudo systemctl enable --now amazon-ssm-agent`。Ubuntu（snap 版）: `sudo snap start --enable amazon-ssm-agent`。ログは `/var/log/amazon/ssm/amazon-ssm-agent.log` |
| SSM への経路がある | プライベートサブネットなら、NAT ゲートウェイ、または VPC エンドポイント（`com.amazonaws.<region>.ssm` / `ssmmessages` / `ec2messages`、プライベート DNS 有効、セキュリティグループで 443 を許可）が必要 |
| インスタンスのメタデータ（IMDS）に到達できる | `HttpEndpoint` が `enabled` であること。コンテナ内から使う場合は `HttpPutResponseHopLimit` に注意 |

SSM に接続できない状態では Session Manager でインスタンスに入れない。インスタンス上を調べるには、EC2 シリアルコンソール（事前に有効化が必要）か SSH を使う。

**確認のしかた**: 対処後、上の `describe-instance-information` で `Online` になることを確認してから、パイプラインを再実行する（`plan` でも確認できる）。

## 2. SSM Agent が接続しない

**症状**: `ping_status` が `ConnectionLost` のまま。ステップ 0 で「SSM Agent が接続していない（状態: ConnectionLost）」、またはステップ 3 で「リリース用インスタンスの SSM Agent の接続が 900 秒以内に完了しなかった」で失敗する。

**意味**: SSM の管理対象としては登録されているが、今は接続していない。ステップ 3 の場合は、AMI 作成時の再起動（または停止中からの起動）の後に戻ってこなかった。

**確認**:

```bash
# インスタンス自体が起動しているか、ステータスチェックに合格しているか
aws ec2 describe-instance-status --instance-ids <インスタンス ID> --include-all-instances \
  --query 'InstanceStatuses[0].[InstanceState.Name,SystemStatus.Status,InstanceStatus.Status]'

# 起動時のコンソール出力（OS の起動が途中で止まっていないか、SSM Agent が起動したか）
aws ec2 get-console-output --instance-id <インスタンス ID> --latest --output text | tail -50
```

**原因と対処**:

| 確認結果 | 原因 | 対処 |
|---|---|---|
| `running` でない、またはステータスチェックが失敗 | 再起動後に OS が正常に起動していない（ディスク容量不足、fstab の誤りなど） | コンソール出力で起動のどこで止まったかを確認し、インスタンス側を直す |
| `running` でステータスチェックも合格 | 再起動後に SSM Agent が自動で起動していない | [1](#1-ssm-の管理対象になっていない) の「SSM Agent の自動起動」を有効にする |
| 時間を置くと `Online` になる | 再接続に時間がかかっている | `timeouts.instance_online_seconds` を延ばす |

## 3. ヘルスチェックが失敗する

**症状**: ステップ 4 で「ヘルスチェックが失敗した（Failed）: health check failed: http://localhost/up did not respond」などで失敗する。AMI は削除済み。

**意味**: 再起動（または起動）の後、アプリが自動で起動していない、または起動したが応答しない。インスタンスは起動したまま残るので、そのまま調べられる（決定事項 D5）。

**確認**:

- ヘルスチェックの出力: CloudWatch Logs の同じロググループの、SSM Run Command のストリーム
- インスタンス上（Session Manager で接続）:

```bash
curl -fsS http://localhost/up
systemctl is-enabled nginx; systemctl status nginx     # 自動起動が有効か、起動しているか
sudo tail -n 100 /var/log/nginx/error.log              # Passenger / Rails のエラー
```

**原因と対処**:

| 原因 | 対処 |
|---|---|
| nginx（Passenger）の自動起動が無効（手作業で起動していた） | `sudo systemctl enable nginx`。リリース検証の手順に自動起動の確認を入れる |
| アプリの起動時のエラー（設定・シークレットの不足、DB に接続できない） | エラーログを確認して直す |
| `last HTTP status: 401`（`HTTP 401: the basic auth credentials were rejected or not sent`） | Basic 認証が必要なのに設定していない（`health_check.basic_auth_parameter_name` を設定する）、またはパラメーターの認証情報が誤っている（`ユーザー名:パスワード` の形式で置き直す） |
| `cannot read the basic auth parameter ...` | リリース用インスタンスのロールに、ヘルスチェックのスタックの管理ポリシー（`BasicAuthParameterReadPolicyArn`）がアタッチされていない。パラメーターがない、名前が違う。カスタマー管理の KMS キーで暗号化している場合は `kms:Decrypt` も必要 |
| `AWS CLI is not installed` | Basic 認証の情報を取り出すために、リリース用インスタンスに AWS CLI が必要。インストールする |
| `/up` 以外のパスで確認すべき | `config/ami_publish.yml` の `health_check.url` を直し、ヘルスチェックのスタックを再生成・再デプロイする |

## 4. AMI の作成が終わらない・失敗する

**症状**: ステップ 2 の進捗ログが長く続く。「available にならなかった」で失敗する。または CodeBuild が 60 分で強制終了される。

**意味**: AMI のスナップショットの取得に時間がかかっている、または失敗した。進捗ログの `snapshots`（例: `snap-0123 45%`）で進み具合がわかる。

**対処**:

| 状況 | 対処 |
|---|---|
| 進捗は進んでいるが遅い | ディスクが大きい・変更量が多いと数十分かかる。異常ではない |
| CodeBuild が 60 分（`timeouts.codebuild_minutes`）で強制終了された | ツールの後始末が動かないため、作成中の AMI が残ることがある。パイプラインの画面で失敗したアクションを**再試行**すると、同じ実行の AMI を再利用して続きから進む。毎回そうなるなら `codebuild_minutes` を延ばすか、`image_available_seconds` をそれより短くしてツールのタイムアウトを先に来させる |
| `failed` になった | AMI は削除済み。一時的な問題のことがあるので再実行する。繰り返すなら EBS ボリュームの状態を確認する |

## 5. 停止中のインスタンスを起動できない

**症状**: ステップ 2a で「リリース用インスタンス ... を起動できなかった」で失敗する。AMI は削除済み。

**原因と対処**:

| 原因 | 対処 |
|---|---|
| キャパシティ不足（`InsufficientInstanceCapacity`） | 時間を置いて再実行する |
| EBS をカスタマー管理の KMS キーで暗号化している | 起動に KMS の権限が必要になることがある。CodeBuild のロールと KMS キーのポリシーを確認する |
| 権限不足（`UnauthorizedOperation`） | パイプラインのスタックが古い（`ec2:StartInstances` の追加前）。仕組みを再デプロイする |

## 6. 起動テンプレートのスタックを更新できない

| 症状（`message`） | 原因 | 対処 |
|---|---|---|
| `起動テンプレート以外の変更が含まれているため中止した` | パラメータの変更で起動テンプレート以外のリソースも変わる状態になっている（テンプレート本体が想定外の形でデプロイされた） | 起動テンプレートのスタックのテンプレートを、`generated/` の正しいものでデプロイし直す。AMI は残っているので、その後に同じ実行を再試行する |
| `更新できる状態ではない（状態: UPDATE_ROLLBACK_FAILED）` など | スタックが異常な状態 | CloudFormation のコンソールでイベントを確認し、`aws cloudformation continue-update-rollback --stack-name <スタック名>` などで復旧してから再実行する |
| `スタックの更新が完了しなかった（状態: UPDATE_ROLLBACK_COMPLETE）` | 更新が失敗してロールバックされた | スタックのイベントで失敗したリソースと理由を確認する。サービスロールの権限不足のことが多い |
| `パラメータ AmiId, AppVersion がない` | 起動テンプレートのスタックが古いテンプレートでデプロイされている | `generated/` のテンプレートでデプロイし直す |

## 7. CodeBuild の install フェーズで失敗する

| 症状 | 原因 | 対処 |
|---|---|---|
| `rbenv: version '3.4.10' not installed` | CodeBuild のイメージが更新され、3.4.10 がなくなった | イメージにある 3.4 系のバージョンを確認し、`internal/definitions/ami_publish_buildspec.go` の `codeBuildRubyVersion` を上げて再生成・反映する |
| `bundle install` がプラットフォームの不一致で失敗する | `Gemfile.lock` の `PLATFORMS` から `x86_64-linux` が消えた（macOS だけで `bundle lock` し直した） | `bundle lock --add-platform x86_64-linux aarch64-linux` で戻す |
| ネイティブ拡張のビルドに失敗する | ビルド環境に C コンパイラがない | CodeBuild 標準イメージでは起きない。独自のイメージを使っている場合はビルドツールを入れる |
| buildspec や `Gemfile` が見つからない | パイプラインのソースのリポジトリのルートが `ami-publish/` になっていない | `ami-publish/` の中身をルートとするリポジトリをソースにする（[確認手順書の手順 0](./ami-publish-environment-verification.md#0-前提の決定-ソースにするリポジトリ)） |

## 8. 終了コード 2（使い方・設定値の誤り）

| 症状（`エラー:` の行） | 対処 |
|---|---|
| `--version を指定する` | パイプラインを変数 `VERSION` なしで実行した。**スタック作成直後の自動実行で出るのは想定どおり**（AWS は何も変更していない）。`--variables name=VERSION,value=vX.Y.Z` を付けて実行する |
| `--version の形式が不正` | `v1.2.3` の形式にする |
| `環境 ... が ... にない` | CodeBuild の環境変数 `AMI_PUBLISH_ENVIRONMENT` と、`config/ami_publish.yml` の環境名が一致しているか確認する |
| `environments.<環境>.... がない` / `形式が不正` | `config/ami_publish.yml` を直し、仕組みの生成ツールで検証する（`go run ./cmd/generate-definitions --check`） |

## 9. 終了コード 3（AWS のエラー）

| `error_class` | 原因 | 対処 |
|---|---|---|
| `...AccessDenied...` / `UnauthorizedOperation` | CodeBuild のロールの権限不足 | パイプラインのスタックが最新か確認し、古ければ再デプロイする。権限は `generated/cloudformation/<環境>/ami-publish-pipeline-stack.yml` の `CodeBuildServiceRole` |
| `Aws::Errors::MissingCredentialsError` | 認証情報がない（手元での実行時） | `AWS_PROFILE` などで認証情報を渡す |
| `Seahorse::Client::NetworkingError` | AWS の API に接続できない | CodeBuild を VPC に置いている場合は経路を確認する（このパイプラインは VPC 配置を前提にしていない） |
| `InvalidInstanceID.NotFound` | `release_instance_id` が誤っている、またはリージョンが違う | `config/ami_publish.yml` を確認する |

## 10. rollback が失敗する

| 症状 | 原因 | 対処 |
|---|---|---|
| `バージョン ... の公開済み AMI が見つからない` | 指定したバージョンの AMI がない、または `Status=published` になっていない（公開の途中で失敗した AMI は対象外） | `aws ec2 describe-images --owners self --filters Name=tag:App,Values=<アプリ> --query 'Images[].[ImageId,Tags]'` で公開済みの AMI とバージョンを確認する |
| `公開済み AMI が複数ある` | 同じバージョンで複数回公開した | 不要な AMI を登録解除する（どちらに戻すか決められないため、ツールは選ばない） |

## 11. 手元での問題

| 症状 | 対処 |
|---|---|
| RSpec で `linked to incompatible .../libruby...` | `.ruby-version` を変えた後、`vendor/bundle` のネイティブ拡張が古い Ruby に対してビルドされたまま。`bundle pristine` で作り直す |
| `go run ./cmd/generate-definitions --check` が差分ありで終了コード 1 | 定義・設定値を変えたのに再生成していない。`go run ./cmd/generate-definitions` で再生成し、差分をレビューする |
| 生成時に `field ... not found`（未知の項目） | `config/ami_publish.yml` に、削除済みの項目（`stack_name`、`codebuild_image` など）が残っている。削除する |
