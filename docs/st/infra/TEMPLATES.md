# CloudFormation のテンプレートの一覧

`docs/st` にある CloudFormation の YAML の定義は 13 ファイル（2026-10-14 時点）。手で書いたものが 11（CloudFormation 8、SAM 3）、自動で作ったものが 2。パスは `docs/st` からの相対パス。

## CloudFormation（そのまま書いたもの）: 8

| ファイル | 中身 | 手順書 |
|---|---|---|
| `infra/cloudformation/api.yaml` | チケット QR API（HTTP API と Lambda 2つ。Go / Node を `Impl` で切り替え） | go/DEPLOY.md・node/DEPLOY.md 4-A |
| `infra/cloudformation/example.yaml` | example.com の QR の API（別スタック） | go/DEPLOY.md・node/DEPLOY.md 6-A |
| `infra/cloudformation/quota-guard.yaml` | 発行の上限（1時間 1 万件・1日 10 万件）。超えたら発行のルートを止める（API のスタックとは別） | infra/RATE_LIMITING.md 7章 |
| `infra/cloudformation/web.yaml` | Web（S3 と CloudFront。直結・統合の2構成） | web/DEPLOY.md 3章 |
| `infra/cloudformation/tickets-network-existing-vpc.yaml` | `tickets` 用のネットワーク（既存の VPC に作る） | notes/tickets-network.md |
| `infra/cloudformation/tickets-network-new-vpc.yaml` | `tickets` 用のネットワーク（VPC から新しく作る） | notes/tickets-network.md |
| `infra/cloudformation/tickets-network-sg-only.yaml` | `tickets` 用のネットワーク（既存のプライベートサブネットを使い、SG だけ作る。N3） | infra/PROD_DEPLOY.md 1.3 |
| `analyzer-stub/network.yaml` | 画像解析のスタブ（Fargate）用の VPC・サブネット・SG | DEPLOY.md 3.4 |

## SAM（CloudFormation の拡張）: 3

| ファイル | 中身 | 手順書 |
|---|---|---|
| `infra/sam/go/template.yaml` | チケット QR API の Go 版（`api.yaml` と同じ内容を SAM で書いたもの） | infra/sam/README.md |
| `infra/sam/node/template.yaml` | 同じく Node 版 | infra/sam/README.md |
| `analyzer-stub/template.yaml` | 画像解析のスタブ（Lambda + Function URL） | DEPLOY.md 3.2 |

## 自動で作ったもの: 2

| ファイル | 中身 |
|---|---|
| `infra/sam/generated/go.cfn.yaml` | `infra/sam/go/template.yaml` を CloudFormation に変換した結果（`infra/sam/translate.py` で作る。見比べ用で、デプロイには使わない） |
| `infra/sam/generated/node.cfn.yaml` | 同じく Node 版 |

## パラメータの書き方

- 手で書いた 11 ファイルのパラメータには、すべて英語の `Description` と、その上の行に日本語の説明のコメント（`# …`）を付ける（2026-10-14 時点で 95 個）
- 自動で作る 2 ファイル（`infra/sam/generated/`）には、SAM の `Description` は写るが、コメントは写らない（変換でコメントは消える）

## YAML 以外

- 画像解析のスタブの Fargate 版は CDK（Python。`analyzer-stub/cdk/`）で定義している。CDK はデプロイのときに CloudFormation を作るが、YAML のファイルとしては置いていない

## 確かめ方

```sh
cd docs/st
# 手で書いた 11 ファイル
uvx cfn-lint==1.57.1 --regions=ap-northeast-1 -- infra/cloudformation/*.yaml infra/sam/*/template.yaml analyzer-stub/network.yaml analyzer-stub/template.yaml
# 自動で作った 2 ファイル（E1161: 仮の S3 バケット名）
uvx cfn-lint==1.57.1 --regions=ap-northeast-1 --ignore-checks E1161 -- infra/sam/generated/*.cfn.yaml
```
