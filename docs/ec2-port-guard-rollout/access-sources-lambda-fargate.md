# 同じリージョンの Lambda・Fargate からサーバーを呼ぶとき、送り元はどこになるか

> 位置付け: 80・443 番を日本と許可した IP アドレスに絞った（[踏み台サーバーから入れる手順](./bastion-install-commands.md)）サーバーを、同じリージョン（東京）の AWS Lambda や AWS Fargate（Amazon ECS のタスク）から呼ぶとき、サーバーから見た送り元のアドレスがどこになるか、許可の一覧（`port_guard_whitelists/allow-ipv4.txt`）に何を書けばよいかをまとめたもの。
>
> 状態: AWS のドキュメント（末尾の「参考」）と照らし合わせてまとめた（2026-11-05）。実際の Lambda・Fargate からは確かめていない。
>
> 作成日: 2026-11-05

## 結論

- 送り元は、**Lambda・Fargate が VPC の中にいるか**と、**サーバーのどのアドレスあてに接続するか**（プライベートのアドレスか、公開のアドレスか）で決まる
- **VPC の中から、サーバーのプライベートのアドレスあてに接続すれば、許可の一覧の VPC の範囲で通る**（追加の設定は要らない）
- 公開のアドレスあてに接続すると、送り元は NAT ゲートウェイや、呼ぶ側の公開のアドレスになる。NAT ゲートウェイの Elastic IP（固定）なら、許可の一覧に足せば通る
- **VPC に入れていない Lambda は、送り元を固定できない**。AWS の東京リージョンの公開のアドレスの範囲を丸ごと許可するのは勧めない（他社の EC2 なども全部入っていて、絞り込みの意味がほとんどなくなる）

## 送り元のアドレス

| 呼ぶ側 | サーバーのどのアドレスあてか | サーバーから見た送り元 | 固定か | 今の許可の一覧で通るか |
|---|---|---|---|---|
| **Lambda（VPC に入れていない。既定）** | 公開のアドレス（ドメイン名） | AWS の東京リージョンの公開のアドレスのどれか（Lambda が自分で管理している VPC から、インターネットに出る） | **固定でない**（実行のたびに変わりうる） | **通らない**（AWS の公開のアドレスは、ほとんどが日本の範囲の一覧に入っていない） |
| **Lambda（VPC に入れた）** | プライベートのアドレス | Lambda が VPC のサブネットに作るネットワークの口の、プライベートのアドレス | サブネットの範囲の中で変わる | **通る**（VPC の範囲を許可している） |
| 同上 | 公開のアドレス（ドメイン名） | NAT ゲートウェイの Elastic IP（VPC に入れた Lambda は、プライベートのサブネットから NAT ゲートウェイを通してインターネットに出る） | **固定** | 通らない（その Elastic IP を許可の一覧に足せば通る） |
| **Fargate**（ECS のタスク） | プライベートのアドレス | タスクのネットワークの口の、プライベートのアドレス（タスクごとに 1 つの口が作られる） | サブネットの範囲の中で変わる | **通る** |
| 同上（パブリックのサブネットで、タスクに公開のアドレスを付けている） | 公開のアドレス | タスクの公開のアドレス | **固定でない**（タスクを起動し直すたびに変わる） | 通らない |
| 同上（プライベートのサブネットで、NAT ゲートウェイを通している） | 公開のアドレス | NAT ゲートウェイの Elastic IP | **固定** | 通らない（Elastic IP を足せば通る） |

同じ VPC の中からでも、**公開のアドレスあてに接続すると、通信はいったん VPC の外に出て戻ってくる**。そのとき送り元は、NAT ゲートウェイや呼ぶ側の公開のアドレスに変わるので、VPC の範囲の許可では通らない。

## どちらのアドレスあてになるか（接続先の書き方）

| 接続先の書き方 | 引いたときのアドレス | 通る道 |
|---|---|---|
| サーバーのプライベートのアドレス（例: `10.0.1.23`） | — | VPC の中 |
| EC2 のプライベートの名前（例: `ip-10-0-1-23.ap-northeast-1.compute.internal`） | プライベートのアドレス | VPC の中 |
| EC2 の公開の名前（例: `ec2-203-0-113-10.ap-northeast-1.compute.amazonaws.com`） | **VPC の中から引くとプライベートのアドレス**、外から引くと公開のアドレス（VPC の DNS の機能。VPC の DNS の設定 `enableDnsSupport`・`enableDnsHostnames` が有効なとき） | VPC の中から引けば VPC の中 |
| Route 53 のプライベートのホストゾーンに登録した名前（例: VPC の中だけで使う `app.internal.example.com` を、プライベートのアドレスに向ける） | プライベートのアドレス | VPC の中 |
| 自分のドメイン名を、公開の DNS で公開のアドレスに向けたもの（例: `www.example.com`） | 公開のアドレス | **VPC の外を回る**（送り元は NAT ゲートウェイなど） |

## 実際にどこから来ているかを確かめる

| 方法 | 見られるもの |
|---|---|
| port-guard の記録（対象のサーバーで `sudo journalctl -k \| grep 'port-guard drop'`） | 捨てた通信の `SRC=`（送り元のアドレス）。止められている相手が分かる（1 分に 10 件まで記録） |
| Apache のアクセスログ | 通った通信の送り元 |
| VPC フローログ | VPC のネットワークの口を出入りした通信の送り元とあて先（設定が要る）。Fargate のタスクの口の通信も記録される |
| Lambda・Fargate の側で、自分の外向きのアドレスを確かめる | `https://checkip.amazonaws.com` を呼ぶと、外から見た自分のアドレスが返る（公開のアドレスあてに出るときの送り元） |
| AWS の公開のアドレスの範囲（`https://ip-ranges.amazonaws.com/ip-ranges.json`） | 記録に出た送り元が AWS のアドレスか、どのリージョンかを調べる。**許可の一覧に丸ごと入れるためのものではない** |

## おすすめ

1. Lambda・Fargate からこのサーバーを呼ぶなら、**VPC に入れて（Fargate は普通 VPC の中）、サーバーのプライベートのアドレス、EC2 のプライベートの名前、または Route 53 のプライベートのホストゾーンの名前で呼ぶ**。許可の一覧の VPC の範囲で通り、設定の追加は要らない
2. 公開のドメイン名で呼ぶ必要があるなら、**プライベートのサブネットから NAT ゲートウェイを通し、その Elastic IP を許可の一覧に書く**（1 つのアドレスなので、`/32` は付けても付けなくてもよい）
3. VPC に入れていない Lambda からは、送り元を固定できないので、許可の一覧では通せない。1 か 2 の形に変える

許可の一覧に書いたら、[踏み台サーバーから入れる手順](./bastion-install-commands.md) の「許可する IP アドレスの一覧を変えるとき」のとおりに流す。

## 参考（AWS のドキュメント）

- [Enable internet access for VPC-connected Lambda functions](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc-internet.html)（Lambda は既定で Lambda が管理する VPC で動き、インターネットに出られる。VPC に入れた Lambda は、プライベートのサブネットから NAT ゲートウェイを通してインターネットに出る。パブリックのサブネットに入れてもインターネットには出られない）
- [Amazon ECS task networking options for Fargate](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-networking.html)（Fargate のタスクごとに、プライベートのアドレスを持つネットワークの口が作られる。パブリックのサブネットでは公開のアドレスを付けられる。プライベートのサブネットでは NAT ゲートウェイを通す。タスクの通信は VPC フローログに記録される）
- [Understanding Amazon DNS](https://docs.aws.amazon.com/vpc/latest/userguide/AmazonDNS-concepts.html)（EC2 の公開の名前は、インスタンスのネットワークの中から引くとプライベートのアドレス、外から引くと公開のアドレスになる。プライベートのホストゾーン）
- [AWS IP address ranges](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ip-ranges.html)（AWS の公開のアドレスの範囲 `ip-ranges.json`）
- [NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)
- [VPC Flow Logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html)
