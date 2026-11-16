# WAF のマネージドルールとログ（オプション）

> 位置付け: **オプション**。採用した B. CloudFront → EC2 の、ステップ 2 の WAF（`<prefix>-step2-waf`）に足す選択肢。既定の WAF は国の絞り込みだけ（[definitions.md の WAF](../definitions.md#ステップ-2-の-waf国の絞り込み)）で、マネージドルールとログは入れていない（2026-11-13 に既定から外した。[README の T10](../README.md#決めたこと)）。ここには、入れるときの方法と、外す前の定義の設定値を残す。手順の全体は [README](../README.md#3-つのステップ)。
>
> 確かめた範囲: AWS WAF の仕様と料金は AWS のドキュメントと照らし合わせた（2026-11-11、2026-11-13）。外す前の定義は `cfn-lint` と CDK の合成まで確かめた（2026-11-12）。**AWS へのデプロイと、実際の要求での誤検知の確認はしていない**。
>
> 作成日: 2026-11-13（`definitions.md` の WAF の節から移した）

## 用語

[README の用語](../README.md#用語)に加えて、次の語を使う。

| 用語 | 指すもの |
|---|---|
| 既定の WAF | 今の `<prefix>-step2-waf`。ルールは `AllowAcmeChallenge` と `BlockOutsideAllowedCountries` の 2 つだけ |
| マネージドルール | AWS が作って保守している WAF のルールの集まり（ルールグループ）。下の「マネージドルールとは」 |
| Count（記録だけ） | ルールに当たった要求を、止めずに数えてラベルを付けるだけの動作。試験に使う |
| ラベル | ルールに当たった要求に付く印（`awswaf:managed:aws:...`）。ログとメトリクスで、どのルールに当たったかが分かる |
| WCU | web ACL のキャパシティの単位。web ACL に入れたルールの合計が上限（1,500）を超えられない |
| 外す前の定義 | マネージドルールとログを入れていた版の定義。コミット `f282149` の `cloudformation/step2-waf.yml` と `cdk/python/tls_termination_cdk/stacks/step2_waf.py` |

## 既定の WAF との違い

| | 既定の WAF（国の絞り込みだけ） | このオプション（マネージドルールとログを足す） |
|---|---|---|
| 止めるもの | 許可する国でなく、例外の IP でもない要求 | 左に加えて、許可する国と例外の IP から来た要求のうち、攻撃の形をしたもの・評判の悪い IP からのもの |
| ルール | 2 つ | 2 つ ＋ マネージドルールのグループ 3 つ |
| 設定値（CDK） | `waf_allowed_countries`、`waf_exception_ipv4_addresses`、`waf_exception_ipv6_addresses` | 左に加えて `waf_managed_rules_mode`、`waf_log_retention_days` |
| 料金（2026-11-13 確認） | web ACL 月 $5 ＋ ルール 2 つで月 $2 ＝ 月 $7 と、100 万リクエストごとに $0.60 | ＋ マネージドルールのグループ 3 つで月 $3（1 つで月 $1）＝ 月 $10 と要求の料金。ほかに CloudWatch Logs の料金 |
| WCU | 約 25 | 約 950（グループが 25・700・200） |
| 誤検知 | 国の判定だけなので、起きにくい | 正しい要求を止めることがある。count で試してから block にする手間が要る |
| 止めた要求の見方 | メトリクスとサンプルのリクエスト | 左に加えて、ログ（全件） |
| 定義の量 | `step2_waf.py` 155 行（コメント込み）、`step2-waf.yml` 138 行 | 外す前は `step2_waf.py` 236 行、`step2-waf.yml` 265 行。量の大半は、Count に上書きするルールの名前の一覧 |

入れる判断の目安: 許可する国（日本）からの攻撃や、脆弱性を探る要求が稼働サーバーのログに目立つなら入れる。アプリが古い（Rails 4.2、Ruby 2.7）ので、既知の悪い入力のグループは効き目がある見込み。入れると、`SizeRestrictions_BODY`（本文 8 KB 超）のように、フォームの送信やファイルのアップロードで当たるルールの見極めが要る。

## マネージドルールとは


AWS が作って保守している WAF のルールの集まり（ルールグループ）。web ACL には、提供元（`AWS`）とグループの名前を書くだけで足せて、中のルールは AWS が更新する。ルールの名前と概要は公開されているが、具体的な条件（文字列や正規表現）は、抜け道を探されないように公開されていない。中のルールは、どれも既定の動作が Block（`AWSManagedIPDDoSList` だけ Count）で、当たった要求にラベル（`awswaf:managed:aws:...`）を付ける。

国の絞り込みとは目的が違う。国の絞り込みは「どこから来たか」で止めるだけなので、許可する国と例外の IP から来る攻撃は通る。マネージドルールは、その通った要求の中身（パス、クエリ、ヘッダー、本文）や送り元の評判を見て止める。このオプションでは、国の絞り込みの後に置く。

| ルールグループ | 見るもの | 主なルール | WCU | ルールの数 |
|---|---|---|---|---|
| `AWSManagedRulesAmazonIpReputationList`（IP の評判） | 送り元の IP だけ | Amazon の脅威情報で、悪いことをしているとされた IP（`AWSManagedIPReputationList`）、AWS のリソースを探っている IP（`AWSManagedReconnaissanceList`）、DDoS に加わっている IP（`AWSManagedIPDDoSList`。既定で Count） | 25 | 3 |
| `AWSManagedRulesCommonRuleSet`（コアルールセット、CRS） | 要求の中身 | Web アプリに広く当てはまる攻撃（OWASP Top 10 に挙がるもの）。クロスサイトスクリプティング、`../../` でのファイルの読み出し（LFI）、外部の URL の読み込み（RFI）、EC2 のメタデータの取り出し（SSRF）、`.log`・`.ini` などの危ない拡張子、User-Agent がない・攻撃の道具の User-Agent、大きすぎる要求（クエリ 2,048 バイト、Cookie 10,240 バイト、本文 8 KB、パス 1,024 バイトを超えるもの） | 700 | 22 |
| `AWSManagedRulesKnownBadInputsRuleSet`（既知の悪い入力） | 要求の中身 | 知られた脆弱性を狙う入力。Log4j（`${jndi:...}`）、Java の逆シリアル化（Spring）、`Host: localhost`、`PROPFIND` メソッド、`web-inf` などのパス、React の CVE-2025-55182 | 200 | 12 |

- コアルールセットと既知の悪い入力は、AWS のドキュメントで基本のグループ（Baseline）に分類されている（コアルールセットは「どの用途でも検討するとよい」とされている）。ボット対策（Bot Control）やアカウント乗っ取り対策のグループは、このオプションに含めていない
- コアルールセットと既知の悪い入力は版（バージョン）を持ち、AWS が更新する（この定義では版を指定していない。版の変更は AWS Managed Rules の変更履歴に載る）。IP の評判のグループは版を持たない
- WCU（web ACL のキャパシティの単位）は上の合計 925 と、自分で書いたルールで、web ACL の上限 1,500 に収まる

## 入れ方（方法論）

最初は **count（記録だけ）** で入れ、ログで誤検知がないことを確かめてから **block** に切り替える（2026-11-11 に決めていた流れ）。切り替えは、[ステップ 3 の片付け](../step3-dns-switch.md#3-5-片付け)が終わって、利用者が CloudFront 経由で使っている状態で、しばらく（例: 1〜2 週間）ログを見てからにする。

| # | 行うこと | 見ること |
|---|---|---|
| 1 | 定義に、マネージドルールのグループ 3 つとログを足す（下の「外す前の定義」）。`waf_managed_rules_mode: count` で `<prefix>-step2-waf` を更新する | 更新の変更セットに、web ACL の変更とロググループ・ログの設定の追加だけが出ること |
| 2 | 利用者の要求を、ログとメトリクスで見る | Count になった要求のラベル（`awswaf:managed:aws:...`）と、その要求が正しい利用か |
| 3 | 誤検知のあるルールを決める | 正しい利用で当たるルール（見込みが高いのは `SizeRestrictions_BODY`） |
| 4 | `waf_managed_rules_mode: block` にして更新する。誤検知のあったルールだけは Count の上書きを残す（定義を、そのルールの名前だけを上書きする形に直す） | 止めた要求のログ。利用者からの問い合わせ |
| 5 | 必要なら、Count の上書きの一覧を短くする | block にした後は、Count に残すルールの名前だけが要る |

方法の要点:

- **ルールを 1 つずつ Count に上書きする**（`RuleActionOverrides`）。ルールグループ全体を Count にする方法（`OverrideAction: Count`）は使わない。AWS のドキュメントでは、グループ全体の上書きは試験に向かないとされている（グループの評価は普段どおりに行われ、最初に当たったルールの結果だけが Count に変わるので、ほかのルールが当たるかは分からない）
- **上書きするルールの名前は、AWS のドキュメントの一覧から写す**（外す前の定義は 2026-11-11 に写した）。グループの版が上がってルールが増えると、増えたルールは上書きされず、count の間も止める。版が上がったら一覧を見直す
- **国の絞り込みの後に置く**（優先順位 2〜4）。マネージドルールのログが、許可する国と例外の IP からの要求だけになり、誤検知を見やすい。既定の WAF の `BlockOutsideAllowedCountries` が「例外の IP を通す」ルールでなく NOT と AND の形なのは、例外の IP もマネージドルールで見るため（通すルールは評価をそこで終える）
- **グループの選び方**: 上の「マネージドルールとは」の 3 つは、どれも追加の料金が料金のページに書かれていないもの（グループごとの月 $1 だけ）。ボット対策（Bot Control）やアカウント乗っ取り対策のグループは、別に検討する

## 外す前の定義の設定値

### 設定値とパラメータ

| CDK の設定値 | CloudFormation のパラメータ | 既定 | 内容 |
|---|---|---|---|
| `waf_managed_rules_mode` | `ManagedRulesMode` | `count` | `count`: 3 つのグループの中のルールを、すべて Count に上書きする。`block`: グループの決めた動作（Block）のまま。CDK は `count`・`block` 以外で合成を止めていた |
| `waf_log_retention_days` | `LogRetentionInDays` | `30` | ログを残す日数。CloudFormation は CloudWatch Logs の決まった値（1、3、5、7、14、30、60、90 など）だけを受ける |

出力は `WebAclArn` に加えて `WebAclLogGroupName`（ロググループの名前）。

### ルール

| ルール | 優先順位 | 動作 | Count に上書きするルール（`count` のとき） |
|---|---|---|---|
| `AllowAcmeChallenge` | 0 | 通す | — |
| `BlockOutsideAllowedCountries` | 1 | 止める | — |
| `AWSManagedRulesAmazonIpReputationList` | 2 | グループの動作（`OverrideAction: None`） | `AWSManagedIPReputationList`、`AWSManagedReconnaissanceList`（`AWSManagedIPDDoSList` は元から Count なので含めない） |
| `AWSManagedRulesCommonRuleSet` | 3 | 同上 | 22 のルールすべて（`NoUserAgent_HEADER` から `CrossSiteScripting_URIPATH` まで。下の YAML） |
| `AWSManagedRulesKnownBadInputsRuleSet` | 4 | 同上 | 12 のルールすべて（`JavaDeserializationRCE_HEADER` から `ReactJSRCE_BODY` まで） |

### ログ

`us-east-1` の CloudWatch Logs のロググループ `aws-waf-logs-<スタック名>`（例 `aws-waf-logs-<prefix>-step2-waf`）に送り、30 日残す。名前は `aws-waf-logs-` で始め、web ACL と同じリージョンとアカウントに置く決まりである。ロググループの書き込みの許可（リソースポリシー）は、ログの設定を作るときに WAF が付ける。ログの設定（`AWS::WAFv2::LoggingConfiguration`）に渡すロググループの ARN は、`Fn::GetAtt` の `Arn` だと末尾に `:*` が付くので、付かない形を組み立てる。

- ログには要求の見出し（ヘッダー）が入る見込みで、Cookie（セッション）が残るかもしれない。どの項目が残るかは、実際のログで確かめる。残したくない項目があれば、ログの設定の `RedactedFields` か、web ACL のデータ保護の設定で消す（AWS のドキュメントでは、`RedactedFields` で消せるのは `UriPath`、`QueryString`、`SingleHeader`、`Method` だけ）
- ログを読める人を、CloudWatch Logs の権限で絞る
- マネージドルールを入れずに、ログだけを足すこともできる（国の絞り込みで止めた要求を全件残したいとき）。足すのは下の「ログ」の部分だけでよい

### 外す前の定義（CloudFormation の YAML）

既定の `cloudformation/step2-waf.yml` に足す部分。CDK は、コミット `f282149` の `stacks/step2_waf.py`（`MANAGED_RULE_GROUPS` と、それを組み立てる繰り返し、ログの部分）と、`configuration.py` の 2 つの設定値と検証を戻す。

パラメータ（`Parameters:` に足す）:

```yaml
  ManagedRulesMode:
    Type: String
    Default: count
    AllowedValues: [count, block]
    Description: >-
      count overrides every rule in the managed rule groups to Count (record only).
      block uses the actions defined by the rule groups. Switch after checking the logs for false positives.
  LogRetentionInDays:
    Type: Number
    Default: 30
    AllowedValues: [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365]
```

条件（`Conditions:` に足す）:

```yaml
  ManagedRulesCountOnly:
    Fn::Equals:
      - Ref: ManagedRulesMode
      - count
```

ルール（web ACL の `Rules:` の、`BlockOutsideAllowedCountries` の後に足す）:

```yaml
        # Managed rule groups. In count mode every rule is overridden to Count (AWS recommends
        # rule action overrides, not the rule group override, for testing).
        - Name: AWSManagedRulesAmazonIpReputationList
          Priority: 2
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesAmazonIpReputationList
              RuleActionOverrides:
                Fn::If:
                  - ManagedRulesCountOnly
                  - - {Name: AWSManagedIPReputationList, ActionToUse: {Count: {}}}
                    - {Name: AWSManagedReconnaissanceList, ActionToUse: {Count: {}}}
                  - Ref: AWS::NoValue
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: AWSManagedRulesAmazonIpReputationList

        - Name: AWSManagedRulesCommonRuleSet
          Priority: 3
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesCommonRuleSet
              RuleActionOverrides:
                Fn::If:
                  - ManagedRulesCountOnly
                  - - {Name: NoUserAgent_HEADER, ActionToUse: {Count: {}}}
                    - {Name: UserAgent_BadBots_HEADER, ActionToUse: {Count: {}}}
                    - {Name: SizeRestrictions_QUERYSTRING, ActionToUse: {Count: {}}}
                    - {Name: SizeRestrictions_Cookie_HEADER, ActionToUse: {Count: {}}}
                    - {Name: SizeRestrictions_BODY, ActionToUse: {Count: {}}}
                    - {Name: SizeRestrictions_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: EC2MetaDataSSRF_BODY, ActionToUse: {Count: {}}}
                    - {Name: EC2MetaDataSSRF_COOKIE, ActionToUse: {Count: {}}}
                    - {Name: EC2MetaDataSSRF_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: EC2MetaDataSSRF_QUERYARGUMENTS, ActionToUse: {Count: {}}}
                    - {Name: GenericLFI_QUERYARGUMENTS, ActionToUse: {Count: {}}}
                    - {Name: GenericLFI_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: GenericLFI_BODY, ActionToUse: {Count: {}}}
                    - {Name: RestrictedExtensions_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: RestrictedExtensions_QUERYARGUMENTS, ActionToUse: {Count: {}}}
                    - {Name: GenericRFI_QUERYARGUMENTS, ActionToUse: {Count: {}}}
                    - {Name: GenericRFI_BODY, ActionToUse: {Count: {}}}
                    - {Name: GenericRFI_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: CrossSiteScripting_COOKIE, ActionToUse: {Count: {}}}
                    - {Name: CrossSiteScripting_QUERYARGUMENTS, ActionToUse: {Count: {}}}
                    - {Name: CrossSiteScripting_BODY, ActionToUse: {Count: {}}}
                    - {Name: CrossSiteScripting_URIPATH, ActionToUse: {Count: {}}}
                  - Ref: AWS::NoValue
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: AWSManagedRulesCommonRuleSet

        - Name: AWSManagedRulesKnownBadInputsRuleSet
          Priority: 4
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesKnownBadInputsRuleSet
              RuleActionOverrides:
                Fn::If:
                  - ManagedRulesCountOnly
                  - - {Name: JavaDeserializationRCE_HEADER, ActionToUse: {Count: {}}}
                    - {Name: JavaDeserializationRCE_BODY, ActionToUse: {Count: {}}}
                    - {Name: JavaDeserializationRCE_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: JavaDeserializationRCE_QUERYSTRING, ActionToUse: {Count: {}}}
                    - {Name: Host_localhost_HEADER, ActionToUse: {Count: {}}}
                    - {Name: PROPFIND_METHOD, ActionToUse: {Count: {}}}
                    - {Name: ExploitablePaths_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: Log4JRCE_HEADER, ActionToUse: {Count: {}}}
                    - {Name: Log4JRCE_QUERYSTRING, ActionToUse: {Count: {}}}
                    - {Name: Log4JRCE_BODY, ActionToUse: {Count: {}}}
                    - {Name: Log4JRCE_URIPATH, ActionToUse: {Count: {}}}
                    - {Name: ReactJSRCE_BODY, ActionToUse: {Count: {}}}
                  - Ref: AWS::NoValue
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: AWSManagedRulesKnownBadInputsRuleSet
```

ログ（`Resources:` に足す）:

```yaml
  # The log group name must start with aws-waf-logs- and be in the same Region as the web ACL.
  WebAclLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName:
        Fn::Sub: aws-waf-logs-${AWS::StackName}
      RetentionInDays:
        Ref: LogRetentionInDays

  WebAclLogging:
    Type: AWS::WAFv2::LoggingConfiguration
    Properties:
      ResourceArn:
        Fn::GetAtt: [WebAcl, Arn]
      # The log group ARN without the trailing ":*" that Fn::GetAtt Arn returns.
      LogDestinationConfigs:
        - Fn::Sub: arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:${WebAclLogGroup}
```

出力（`Outputs:` に足す）:

```yaml
  WebAclLogGroupName:
    Value:
      Ref: WebAclLogGroup
```

## 確かめること

| 項目 | 内容 |
|---|---|
| 誤検知 | count の間のログで、正しい利用に当たるルール。特に `SizeRestrictions_BODY`、`NoUserAgent_HEADER`（監視の道具など User-Agent のない要求）、`GenericLFI_*`（パスに `../` を含む正しい要求があるか） |
| ログの項目 | Cookie などの残したくない項目が残るか |
| 版の更新 | コアルールセットと既知の悪い入力の版が上がったときに、Count の上書きの一覧から漏れたルールがないか |

## 参考

AWS のドキュメントと照らし合わせた（2026-11-11、2026-11-13）。

- [Baseline rule groups（CommonRuleSet と KnownBadInputsRuleSet の名前、WCU、ルールの一覧と概要、大きさの上限）](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-baseline.html)（2026-11-13）
- [IP reputation rule groups（AmazonIpReputationList、WCU 25、版を持たない、AWSManagedIPDDoSList は既定で Count）](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-ip-rep.html)（2026-11-13）
- [Overriding rule group actions（試験にはルールごとの Count の上書きを使う、グループ全体の Count は試験に向かない）](https://docs.aws.amazon.com/waf/latest/developerguide/web-acl-rule-group-override-options.html)（2026-11-13）
- [AWS WAF Pricing（マネージドルールグループ 1 つで月 $1）](https://aws.amazon.com/waf/pricing/)（2026-11-13）
- [AWS::WAFv2::LoggingConfiguration（送り先は aws-waf-logs- で始める、RedactedFields）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-wafv2-loggingconfiguration.html)
- [Sending web ACL traffic logs to CloudWatch Logs（同じリージョンとアカウント）](https://docs.aws.amazon.com/waf/latest/developerguide/logging-cw-logs.html)
- [AWS::Logs::LogGroup（GetAtt の Arn は末尾に :* が付く）](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-logs-loggroup.html)
