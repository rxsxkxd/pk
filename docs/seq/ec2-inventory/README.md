# EC2 インスタンスの棚卸し

AWS アカウントの 1 リージョンにある EC2 インスタンスを一覧にし、インスタンスごとに設定・ベース OS・AMI・SSM の状態を 1 行の JSON（JSONL）で出力するツール。OS の更新計画（Amazon Linux 2 からの移行など）や、古い AMI・IMDSv1 のままのインスタンスを探すのに使う。

同じ出力を返す実装を 3 つ置いている。環境に合わせて使いやすいものを選ぶ。

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル | [`shell/ec2-inventory.sh`](./shell/ec2-inventory.sh) | bash, AWS CLI v2, jq |
| Ruby | [`ruby/ec2_inventory.rb`](./ruby/ec2_inventory.rb) | Ruby 3.0 以上, gem `aws-sdk-ec2` と `aws-sdk-ssm`（[`ruby/Gemfile`](./ruby/Gemfile)） |
| Python | [`python/ec2_inventory.py`](./python/ec2_inventory.py) | Python 3.9 以上, `boto3`（[`python/requirements.txt`](./python/requirements.txt)） |

## フォルダ構成

```
ec2-inventory/
├── README.md                 # このファイル
├── ami-os-patterns.json      # AMI 名 → ベース OS の対応表（3 つの実装で共通）
├── shell/ec2-inventory.sh    # シェル版（AWS CLI + jq）
├── ruby/
│   ├── Gemfile
│   └── ec2_inventory.rb      # Ruby 版（aws-sdk-ec2, aws-sdk-ssm）
└── python/
    ├── requirements.txt
    └── ec2_inventory.py      # Python 版（boto3）
```

## 使い方

対象のアカウントとリージョンは、AWS の標準の設定（`AWS_PROFILE`、`AWS_REGION`、`~/.aws/config` など）で決まる。結果は標準出力に出るので、ファイルに保存して jq などで絞り込む。

```bash
# シェル
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/ec2-inventory.sh > ec2.jsonl

# Ruby
cd ruby && bundle install
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 bundle exec ruby ec2_inventory.rb > ../ec2.jsonl

# Python
cd python && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 .venv/bin/python ec2_inventory.py > ../ec2.jsonl
```

### 絞り込みの例

```bash
# Amazon Linux 2 以前で動いているインスタンス
jq -r 'select(.base_os | test("^Amazon Linux( 2)?$")) | [.instance_id, .name, .base_os, .base_os_source] | @tsv' ec2.jsonl

# OS を推定でしか判定できなかったもの（SSM の報告が無い）
jq -r 'select(.base_os_source != "ssm") | [.instance_id, .name, .base_os_source, .image.name] | @tsv' ec2.jsonl

# IMDSv2 を必須にしていないもの
jq -r 'select(.imds_http_tokens != "required") | [.instance_id, .name] | @tsv' ec2.jsonl

# AMI が登録解除済み、または非推奨日を過ぎたもの
jq -r 'select(.image == null or (.image.deprecation_time != null and .image.deprecation_time < (now | todate))) | [.instance_id, .name, .image_id] | @tsv' ec2.jsonl

# SSM の管理対象になっていない、または接続が切れているもの
jq -r 'select(.ssm == null or .ssm.ping_status != "Online") | [.instance_id, .name, (.ssm.ping_status // "未登録")] | @tsv' ec2.jsonl
```

## 必要な IAM 権限

読み取りだけで、インスタンスの設定は変えない。

- `ec2:DescribeInstances`
- `ec2:DescribeImages`
- `ssm:DescribeInstanceInformation`

`ssm:DescribeInstanceInformation` が拒否されたときは、SSM の情報なしで続ける。このとき、すべてのインスタンスの `errors` にそのエラーが記録され、ベース OS は AMI 名からの推定になる。`ec2:DescribeInstances` と `ec2:DescribeImages` が失敗したときは、結果が不完全になるので途中で止まる。

## API の呼び出し回数

| API | 回数 |
|---|---|
| `DescribeInstances` | 1 回（ページ分） |
| `DescribeImages` | インスタンスが使っている AMI の種類を 100 個ずつまとめた回数 |
| `DescribeInstanceInformation`（SSM） | 1 回（ページ分） |

インスタンスごとの呼び出しは無い。インスタンスが何台あっても、AMI の種類が 100 以下なら呼び出しは 3 回（とページ分）で済む。

AMI は ID を指定して引くと、登録解除済みの AMI が 1 つでも混ざっているだけで呼び出し全体がエラーになる。そのため、ID ではなく `image-id` のフィルタで引いている。登録解除済みの AMI は、出力の `image` が `null` になる。

## 出力の項目

1 行に 1 インスタンス。終了済み（`terminated`）のインスタンスは含めない。どの実装でも、項目の名前と順番は同じになる。値が無い項目は `null`、リストの項目は空の配列 `[]` になる。日時は UTC の `YYYY-MM-DDTHH:MM:SSZ` にそろえている。

| 項目 | 内容 | 例 |
|---|---|---|
| `instance_id` | インスタンス ID | `"i-0123456789abcdef0"` |
| `name` | `Name` タグ | `"web-1"` |
| `state` | `pending` / `running` / `stopping` / `stopped` / `shutting-down` | `"running"` |
| `instance_type` | インスタンスタイプ | `"t3.medium"` |
| `architecture` | `x86_64` / `arm64` | `"x86_64"` |
| `platform_details` | 課金上のプラットフォーム（`Linux/UNIX`、`Windows`、`Red Hat Enterprise Linux` など） | `"Linux/UNIX"` |
| `base_os` | ベース OS（下の「ベース OS の判定」を参照） | `"Amazon Linux 2023"` |
| `base_os_source` | `base_os` を何から判定したか（`ssm` / `ami_name` / `platform_details`） | `"ssm"` |
| `image_id` | 起動に使った AMI の ID | `"ami-0123456789abcdef0"` |
| `image` | AMI の `{name, description, owner_id, creation_date, deprecation_time}`。登録解除済みなら `null` | |
| `launch_time` | 最後に起動した日時 | `"2026-09-01T01:00:00Z"` |
| `availability_zone` | アベイラビリティーゾーン | `"ap-northeast-1a"` |
| `vpc_id` / `subnet_id` | VPC とサブネット | |
| `private_ip_address` / `public_ip_address` | IP アドレス。パブリック IP が無ければ `null` | |
| `security_group_ids` | セキュリティグループ | `["sg-0123"]` |
| `iam_instance_profile_arn` | インスタンスプロファイル | |
| `key_name` | キーペア名 | |
| `imds_http_tokens` | `required` なら IMDSv2 のみ、`optional` なら IMDSv1 も使える | `"required"` |
| `auto_scaling_group` | 所属する Auto Scaling グループ（`aws:autoscaling:groupName` タグから） | |
| `launch_template` | 起動に使った起動テンプレートの `{id, version}`（`aws:ec2launchtemplate:*` タグから） | |
| `ssm` | SSM エージェントの `{ping_status, agent_version, platform_type, last_ping_at}`。SSM の管理対象でなければ `null` | |
| `tags` | すべてのタグ（キー → 値） | `{"Name": "web-1", "env": "prod"}` |
| `errors` | 取得に失敗したもの。`{operation, code, message}` のリスト | `[]` |

### ベース OS の判定

次の順で、最初に決まったものを使う。`base_os_source` を見れば、どれで決まったかがわかる。

1. **`ssm`**: SSM エージェントが報告した OS 名と版（`PlatformName` と `PlatformVersion` をつないだもの。例: `Amazon Linux 2023`、`Ubuntu 22.04`、`Red Hat Enterprise Linux 9.4`）。OS の中から報告された値なので、いちばん確か。
2. **`ami_name`**: AMI 名を [`ami-os-patterns.json`](./ami-os-patterns.json) の正規表現に上から順に当てて、最初に一致したもの。AWS やディストリビューションが公開している AMI の名前の付け方に合わせてある。
3. **`platform_details`**: どちらでも決まらないときは、課金上のプラットフォーム（`Linux/UNIX` など）をそのまま入れる。OS の種類まではわからない。

自前で作った AMI（たとえば `docs/ec2/ami-publish/` で作る AMI）は、名前が `ami-os-patterns.json` の形に合わないので 2. では決まらない。そうしたインスタンスの OS を知るには、SSM エージェントを動かして 1. で判定させる。

## わかっている制約

- **SSM の管理対象でないインスタンスの OS は推定になる。** AMI 名で判定できるのは、AWS などが公開している AMI から直接起動したインスタンスだけ。起動後に OS を更新していても、AMI 名からの判定には反映されない。
- **Windows の `base_os` は長い名前になる。** SSM の報告では `Microsoft Windows Server 2022 Datacenter 10.0.20348` のような形になる。
- **EBS ボリュームの大きさや暗号化は出さない。** `DescribeVolumes` の呼び出しが増えるため。
- **`ami-os-patterns.json` は手で更新する。** 新しい OS の版が出たら追記する。`base_os_source` が `platform_details` のインスタンスは、上の絞り込みの例で見つけられる。
- **1 回の実行で見るのは 1 リージョンだけ。**
