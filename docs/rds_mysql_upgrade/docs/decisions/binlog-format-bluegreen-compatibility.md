# Blue `MIXED` → Green `ROW` の Blue/Green レプリケーション互換性

> 対象: Amazon RDS for MySQL 8.0（Blue）から MySQL 8.4（Green）への Blue/Green Deployments
>
> 結論: Blue が `binlog_format=MIXED`、Green が `binlog_format=ROW` の構成で、Blue/Green のレプリケーションを作成できる。Blue を `ROW` に事前変更することは、RDS for MySQL の Blue/Green 作成の必須条件ではない。

## 前提

RDS Blue/Green Deployments では、RDS が Blue の DB インスタンスをコピーして Green を作成し、Blue から Green へのレプリケーションを構成する。RDS for MySQL の作成前提として AWS が明示しているのは、自動バックアップを有効にすることである。

Green 作成時には、Green だけに別の DB パラメータグループを指定できる。MySQL 8.4 用の `mysql8.4` パラメータグループで `binlog_format=ROW` を使っても、Blue 側の 8.0 パラメータグループを `ROW` に変更する必要はない。

## なぜ成立するか

`binlog_format` は、サーバーが**自分の更新をバイナリログへ書き込む形式**を決める。Blue が `MIXED` の場合、各処理は MySQL のルールに従って statement 形式または row 形式のイベントとして Blue のバイナリログへ記録される。

Green は Blue のバイナリログイベントを受信して適用する。レプリカは、受信イベントの形式を自動的に認識するため、Green 自身の `binlog_format=ROW` が、Blue の `MIXED` イベントを拒否したり ROW へ変換したりするわけではない。

```text
Blue: MySQL 8.0 / binlog_format=MIXED
  └─ 更新ごとに statement または row のイベントを binlog に記録
       └─ RDS が構成したレプリケーションで Green が受信・適用
            └─ Green: MySQL 8.4 / binlog_format=ROW
                 └─ Green 自身が将来書き込む binlog の形式は ROW
```

## 時点ごとの意味

| 時点 | Blue の `binlog_format` | Green の `binlog_format` | 意味 |
|---|---|---|---|
| Blue/Green 作成・追従中 | `MIXED` | `ROW` | Blue が出力したイベントを Green がその形式のまま適用する。構成可能。 |
| スイッチオーバー後 | 旧 Blue の設定 | 新本番 Green は `ROW` | Green の新規書込みは ROW 形式でバイナリログに記録される。 |

## `ROW` を設定する意味

Green の `ROW` は、Blue/Green を作成するための前提条件ではない。MySQL 8.4 の既定値が `ROW` であることに合わせる、または今後の通常レプリケーションにおける整合性・運用方針を明確にする目的で設定する。

Blue も `ROW` に統一したい場合は、移行作業に混在させず、アプリケーション・監視・バイナリログ量への影響を評価した別変更として扱う。RDS for MySQL の `binlog_format` は動的パラメータであり、値の変更に DB 再起動は不要である。

## Green での確認項目

- [ ] Green の `SELECT VERSION()` が想定する 8.4 パッチバージョンである。
- [ ] Green の `SHOW VARIABLES LIKE 'binlog_format';` が `ROW` である（Green 側の設定意図を確認）。
- [ ] Blue/Green デプロイの状態が `AVAILABLE` である。
- [ ] レプリケーション遅延がゼロであり、RDS イベント・エラーログに異常がない。
- [ ] 代表的な読み取り・書き込み・バッチ処理を Green で検証する。

## 注意事項

- `MIXED` では、Blue の各イベントがすべて ROW 形式になるわけではない。statement 形式で記録される更新もある。
- `ROW` への統一は、Blue/Green 成立可否ではなく、通常の MySQL レプリケーションの整合性・互換性・ログ量を踏まえた運用判断である。
- 本書は RDS for MySQL の Blue/Green Deployments を対象とする。Aurora MySQL、外部レプリケーション、AWS DMS にはそれぞれ別の前提条件がある。

## リスク 1: Blue を事前に無停止で `ROW` へ変更する

RDS for MySQL の `binlog_format` は動的パラメータであり、パラメータグループ変更の反映に DB 再起動は不要である。これは「無停止で変更可能」を意味するが、「本番書込みへの影響がない」ことを保証するものではない。

| リスク | 内容 | 緩和策 |
|---|---|---|
| 書込み負荷・バイナリログ量の変化 | ROW は行変更を記録するため、処理内容によってはバイナリログ量、ネットワーク転送量、`WriteIOPS`、レプリケーション遅延が増える。 | 本番相当の検証環境で計測し、本番では低負荷時間帯に変更する。変更前後の `WriteIOPS`、レプリケーション遅延、空き容量を監視する。 |
| 既存セッションとの切替境界 | MySQL の `binlog_format` はグローバル／セッションの性質を持つ。グローバル値を変更しても、既存接続のセッション値には直ちに反映されない場合がある。変更直後のログ形式が接続ごとに混在し得る。 | 接続プールの再接続方針を確認し、必要に応じて計画的に接続を入れ替える。変更直後は `SHOW VARIABLES` を新規接続で確認する。 |
| 非 ROW 対応ストレージエンジンの影響 | ROW 形式でログ記録できないストレージエンジンを使う書込みは失敗する可能性がある。 | 変更前にユーザースキーマの非 InnoDB テーブルを棚卸し・解消する。特に MyISAM 等の残存を確認する。 |
| 監視・外部連携への影響 | binlog を読む ETL、監査、レプリカ、独自ツールが statement 形式を前提にしている場合、解析・容量・遅延特性が変わる。 | binlog 利用者を棚卸しし、対象ツールの ROW 対応と性能を検証する。 |
| 切戻しの複雑さ | 値自体は動的に戻せるが、既に生成・消費された ROW イベントを statement 形式へ戻すことはできない。 | 変更を移行と別チケットに分離し、観測期間と中止基準を設ける。 |

この変更は DB 再起動を伴わない一方、Blue の本番書込み経路に直接作用する。従って「無停止」ではあっても「メンテナンスレス」とは扱わない。

## リスク 2: Blue `MIXED` と Green `ROW` の異なる設定でレプリカを構築する

RDS Blue/Green では Green 用に別の DB パラメータグループを指定できる。Blue が出力済みのイベントを Green が適用する間は、Green の `binlog_format` が受信イベントの形式を変えることはないため、設定差そのものはレプリケーション阻害要因ではない。

| リスク | 内容 | 緩和策 |
|---|---|---|
| 設定差による切替後の挙動差 | スイッチオーバー後の Green は新本番として ROW 形式で新規書込みを記録する。binlog を消費する外部ツール、下流レプリカ、監視がある場合、切替後にログ形式が変わる。 | binlog の消費者・下流連携を棚卸しし、ROW 対応と切替後の動作を Green で検証する。 |
| 障害解析の複雑化 | Blue と Green の設定が異なるため、性能差・ログ量・レプリケーション遅延の原因を調査する際に変数が 1 つ増える。 | 差分を `binlog_format` に限定し、CloudFormation テンプレート・変更記録・Green 検証結果を証跡化する。 |
| Green での書込みテスト | Green は通常 read-only である。検証のために Green へ書き込むと、設定差にかかわらず Blue とのレプリケーション競合や意図しないデータ差分を起こし得る。 | Green の書込みは原則行わない。必要な書込み検証は隔離した復元機で行うか、影響と再作成手順を承認する。 |
| 将来の構成変更 | スイッチオーバー後、ROW 形式を前提とした運用へ移行する。旧 Blue を使った巻戻しや外部レプリケーション設計を考える場合は、ログ形式差を考慮する必要がある。 | 切戻し可能期間、データ差分の扱い、下流連携の再設定手順を作業計画へ含める。 |

## 2 つのリスクの評価と推奨

| 選択肢 | Blue 本番への直接影響 | Blue/Green 作成への影響 | 切替後の確認事項 | 総合評価 |
|---|---|---|---|---|
| Blue を事前に `ROW` へ変更する | あり。書込み負荷、既存セッション、binlog 利用者へ影響し得る。 | 必須ではない。 | Blue と Green の形式差は減る。 | **移行のためだけには推奨しない。** ROW 標準化の独立した目的があり、事前検証・観測期間を確保できる場合に限る。 |
| Blue=`MIXED` のまま、Green=`ROW` で作成する | なし。Blue の設定を変えない。 | 構成可能。 | 切替後の binlog 消費者・下流連携が ROW に対応することを確認する。 | **通常はこちらを推奨。** MySQL 8.4 の既定値に沿い、移行前の本番変更を増やさない。 |

結論として、Blue/Green の成立だけを目的に Blue を `ROW` に変更する合理性はない。まずは Blue=`MIXED`／Green=`ROW` で Green を構築し、レプリケーション、代表ワークロード、binlog 消費者を検証する。Blue の ROW 統一は、必要性が別途認められた場合に、移行とは分離した変更として実施する。

## 参考

- [RDS Blue/Green Deployments の作成](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-creating.html)
- [RDS for MySQL のバイナリログ形式](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.MySQL.BinaryFormat.html)
- [MySQL: Replication Formats](https://dev.mysql.com/doc/refman/8.0/en/replication-formats.html)
- [MySQL: Replication FAQ](https://dev.mysql.com/doc/refman/8.0/en/faqs-replication.html)
