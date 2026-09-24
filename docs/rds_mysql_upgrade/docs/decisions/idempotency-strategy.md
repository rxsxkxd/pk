# 各フェーズの冪等性戦略

> 位置づけ: 現行スクリプトの冪等性を実装ベースで評価し、あるべき姿と判定基準をまとめる。
> 対象: `scripts/` 配下の Step 1・3・4・5・7。個別の不具合報告ではなく、判定基準の統一が主題である。
>
> **実施状況**: 着手順の 1〜5（config への移行元宣言の追加、Step 5・7・3 の判定見直し、終了コードの統一）は**実装済み**。6（Step 1 の鮮度管理、Step 4 の証跡一意化）は未着手。本文の「現状」は実装前の記述であり、問題の所在を示すために残している。

## 判定の基準: 「実行したか」ではなく「望ましい終了状態に到達しているか」

冪等性の判定方法には 3 段階があり、**現行実装の多くは第 1 段階に留まっている。**

| 段階 | 判定方法 | 扱えないもの |
|---|---|---|
| ① 存在ベース（現状の多く） | リソースがあるか無いか | 遷移中・異常状態 |
| ② 状態ベース（あるべき姿） | 状態機械のどこにいるかで分岐 | 複数リソースの部分完了 |
| ③ 終了状態ベース（最終形） | 望ましい終了状態との差分だけ適用 | — |

判定の前提となるのは Blue/Green Deployment の状態機械である。

```
PROVISIONING → AVAILABLE → SWITCHOVER_IN_PROGRESS → SWITCHOVER_COMPLETED → DELETING → 消滅
                    ↓                    ↓
        INVALID_CONFIGURATION    SWITCHOVER_FAILED
```

**現行スクリプトは `AVAILABLE` か否かしか見ておらず、遷移中の 3 状態と異常系 2 状態を扱っていない。** これが以降で述べる問題の共通原因である。

## 二層の判定: 「結果の観測」と「安全弁」

状態機械だけを見る設計には限界がある。Deployment は cleanup で削除されるため、**リソースが消えた後は状態を問い合わせられない。** そこで判定を 2 層に分ける。

| 層 | 見るもの | 答える問い |
|---|---|---|
| **① 結果の観測** | 移行元インスタンスの**エンジンバージョンとパラメータグループ** | 達成したい結果は既に得られているか |
| **② 安全弁** | Deployment の `Status` | 今アクションを起こしてよいか（実行中でないか） |

### なぜバージョンとパラメータグループが結果の観測になるのか

切替時、RDS は blue を `<name>-old1` へリネームし、green が `<name>` を引き継ぐ。したがって `source_db_instance_identifier` が指す実体は次のように変わる。

| 時点 | `<source_id>` の実体 |
|---|---|
| 切替前 | 8.0 ＋ 旧パラメータグループ |
| 切替後 | **8.4 ＋ 新パラメータグループ** |

これは Deployment というリソースの状態ではなく、**達成したい結果そのものを直接観測している。** 決定的な利点は、**Deployment が削除された後も判定できる**ことである。cleanup 実行後は `describe-blue-green-deployments` が何も返さないため、状態機械だけに頼る現行の `switchover.sh` は `exit 1`（Deployment not found）になる。バージョン基準なら「既に 8.4 なので完了済み」と正しく `exit 0` を返せる。

### 既存の暗黙のガードを明示化することでもある

`create_blue_green_deployment.sh` には既に同種のチェックがハードコードされている。

```python
i["EngineVersion"].startswith("8.0.") or throw(SystemExit(f"Source DB engine must be MySQL 8.0: ..."))
```

これを設定ファイル駆動にするのは、**既にある考え方の一般化**であり、新しい概念の持ち込みではない。

### 設定ファイルへの追加

移行元の宣言を追加し、config を「X から Y へ」という遷移全体の宣言にする。

```yaml
services:
  example-service:
    source_db_instance_identifier: example-service-production-mysql80
    source_engine_version: "8.0"                              # 追加
    source_db_parameter_group_name: ...-production-mysql80-v3 # 追加
    target_engine_version: 8.4.10
    target_db_parameter_group_name: ...-production-mysql84-v1
```

**エンジンバージョンは `major.minor` へ正規化してから比較する。** 厳密一致にすると、RDS の自動マイナーバージョンアップグレードで `8.0.44` が `8.0.46` になった瞬間にパイプラインが止まる。

当初は前方一致（`verify_green.sh` の `[[ "$green" == "$target"* ]]` に倣う）を想定したが、**テーブル駆動テストで破綻が見つかった。** `target_engine_version` は `create-blue-green-deployment` の `--target-engine-version` へ渡す都合で完全なパッチ版（`8.4.10`）を宣言する必要があり、前方一致では切替後のパッチ更新（`8.4.11`）を弾いてしまう。

```
移行後・自動パッチ更新後   8.4.11 vs 8.4.10*  -> unknown（誤判定）
```

本判定の目的は「旧メジャーバージョンか新メジャーバージョンか」の判別であり、`major.minor` がちょうど必要な粒度である。パッチレベルの厳密な検証は `create_blue_green_deployment.sh` と `verify_green.sh` が別途行うため、ここで担う必要はない。

パラメータグループ名は正規化の余地がないため厳密一致とする。移行と無関係に blue の PG を差し替えた場合は止まるが、その場合は止まるべきである。

### この判定だけでは足りない範囲

| 対象 | 効くか | 理由 |
|---|---|---|
| **Step 5: switchover** | **効く**（主判定にできる） | 切替の有無が直接現れる。Deployment 消滅後も機能する |
| Step 3: build-green | 部分的（フェーズガードとして） | `PROVISIONING` / `AVAILABLE` / `INVALID_CONFIGURATION` は**すべて source が 8.0 のまま**起こるため区別できない |
| Step 7: cleanup | 効かない | 旧 Blue（`-old1`）の存在確認が必要で、source のバージョンは何も教えない |

また、`SWITCHOVER_IN_PROGRESS` の間はリネームが未完了のため `<source_id>` は 8.0 のままである。**バージョンだけで判定すると「まだ切替前」と誤認し、切替中に再度 `switchover-blue-green-deployment` を呼ぶ。** 安全弁としての `Status` 確認は依然として必要である。

### 結果と経路を区別しないことの含意

この判定は**結果**を見るため、「誰かが blue を手動でインプレースアップグレードした」場合も「完了」と判定する。本番が 8.4 で動いている以上、何もしないという結論は安全側であり実害は小さい。ただし**経路の正しさまでは保証しない**という理解は必要である。

## フェーズ別の評価

### Step 1: 成立条件チェック — 冪等性は自明に成立。論点は鮮度である

| 観点 | 内容 |
|---|---|
| 現状 | 読み取り API のみ。AWS を変更しないため再実行・並行実行とも安全 |
| あるべき姿 | 冪等性の議論対象外。代わりに**結果の鮮度**を管理する |
| 基準 | 変更しないこと自体が保証。判定入力を保存し、同じ判定を再現できること |

実際の課題は冪等性ではなく鮮度である。`metadata.json` は `collected_at` を持つが、**後続の `build_green.sh` はこれを参照しない。** 1 か月前の成立条件チェックの結果のまま build を実行できてしまう。

収集（`collect_blue_green_prereqs.sh`）と判定（`evaluate_blue_green_prereqs.rb`）を分離している設計は既に正しく、同じ JSON に対して何度でも同じ判定が出る。これは冪等性より価値のある性質である。

### Step 3: build-green — 存在ベースの弊害が最も出ている

```bash
existing_id=$(... --query 'BlueGreenDeployments[0].BlueGreenDeploymentIdentifier')
if [[ -n "$existing_id" && "$existing_id" != None ]]; then
  echo "Blue/Green Deployment already exists: $existing_id"
  exit 0    # ← 状態を見ずに成功として返している
fi
```

現状の穴を状態別に整理する。

| 実状態 | 現状の挙動 | 問題 |
|---|---|---|
| `PROVISIONING` | 「既に存在」→ `exit 0` | 未完成なのに成功。直後の verify が失敗する |
| `INVALID_CONFIGURATION` | 「既に存在」→ `exit 0` | **失敗した Deployment が残る限り永久に成功を返す**（サイレント失敗） |
| `SWITCHOVER_COMPLETED` | 「既に存在」→ `exit 0` | フェーズを越えているのに build が成功扱い |
| スナップショットが `failed` | 作成をスキップして `wait` へ | タイムアウトまでブロックされる |

**あるべき姿**: 二層で判定する。まず結果を観測してフェーズを越えていないかを確認し、通過後に状態機械で分岐する。

**第 1 層（フェーズガード）**

| source の状態 | 動作 |
|---|---|
| 8.4 ＋ 新 PG | **`exit 0`**（切替済み。build の対象ではない） |
| 8.0 ＋ 旧 PG | 第 2 層へ進む |
| どちらでもない | `exit 1`（想定外のドリフト） |

このガードは現状の実害を 1 つ塞ぐ。**cleanup 完了後に `build: approved` のまま再実行すると、Deployment が存在しないため現行実装は新規作成へ進む。** 内側の `create_blue_green_deployment.sh` が 8.0 でないことを検出して失敗するため事故には至らないが、「移行は完了している」ではなく分かりにくいエラーになる。第 1 層はこれを明示的な成功として扱う。

**第 2 層（状態機械）**

| Deployment | 動作 |
|---|---|
| 無い | 作成する |
| `PROVISIONING` | 待機する（または成功として返し、判定を verify に委ねる） |
| `AVAILABLE` | 何もしない（成功） |
| `INVALID_CONFIGURATION` | 失敗させる（削除は人が判断する） |
| `SWITCHOVER_COMPLETED` 以降 | 失敗させる（build の対象ではない） |

**`PROVISIONING` / `AVAILABLE` / `INVALID_CONFIGURATION` はすべて source が 8.0 のまま起こる。** 第 1 層では区別できないため、build-green では第 2 層が本体である。

保護スナップショットも同様に `Status` を見て、`available` 以外（`creating` / `failed`）を区別する必要がある。

### Step 4: verify-green — 読み取り専用。論点は証跡の一意性である

| 観点 | 内容 |
|---|---|
| 現状 | 読み取りのみ。`actions` も参照しない。`AVAILABLE` 以外は `exit 1` |
| あるべき姿 | 冪等性は成立済み。**同じ実行が同じ結果を返さないのは正常である** |
| 基準 | 読み取り専用であること。加えて判定入力を保存し、後から再現できること |

`ReplicaLag` は時間変動するため、2 回実行して結果が違うのは正しい挙動である。ここを冪等にしようとすると検証の意味が失われる。

実際の課題は証跡側にある。`--output-dir` を同じにすると `green-verification-report.md` が上書きされ、「いつの検証結果か」が消える。承認の根拠として使うには、実行ごとに一意なディレクトリが要る。

### Step 5: switchover — 冪等ではない。最大の設計上の穴である

```bash
[[ "$status" == 'AVAILABLE' ]] || { echo "Switchover requires AVAILABLE status; current status: $status" >&2; exit 1; }
```

**2 回目の実行は必ず失敗する。** 切替後の状態は `SWITCHOVER_COMPLETED` であり `AVAILABLE` ではないためである。

| 実状態 | 現状 | あるべき姿 |
|---|---|---|
| `AVAILABLE` | 切替を実行 | 同じ |
| `SWITCHOVER_IN_PROGRESS` | **`exit 1`** | 完了を待って成功 |
| `SWITCHOVER_COMPLETED` | **`exit 1`** | **何もせず `exit 0`** |
| `SWITCHOVER_FAILED` | `exit 1` | 同じ（失敗） |
| Deployment が無い（cleanup 済み） | **`exit 1`** | **何もせず `exit 0`** |

**「既に目的を達している」と「異常で達せない」が、どちらも `exit 1` で区別できない。** CI がリトライすると失敗が続き、切替は成功しているのにジョブが赤いまま、という状態になる。

**あるべき姿**: このフェーズは**バージョン ＋ PG による結果の観測を主判定にできる。** 切替の有無が `<source_id>` の実体に直接現れ、かつ Deployment 消滅後も機能するためである。

| source の状態 | Deployment | 動作 |
|---|---|---|
| 8.4 ＋ 新 PG | **問わない（消えていてもよい）** | **何もせず `exit 0`**（完了済み） |
| 8.0 ＋ 旧 PG | `AVAILABLE` | 切替を実行 |
| 8.0 ＋ 旧 PG | `SWITCHOVER_IN_PROGRESS` | 完了を待つ |
| 8.0 ＋ 旧 PG | 無い / `SWITCHOVER_FAILED` | `exit 1` |
| どちらでもない | — | `exit 1`（想定外のドリフト） |

`SWITCHOVER_IN_PROGRESS` の行が、バージョン判定を単独で使えない理由である。リネームが完了するまで `<source_id>` は 8.0 のままであり、バージョンだけでは「まだ切替前」と誤認して切替中に再度 API を呼ぶ。**`Status` は安全弁として残す。**

**基準**: 成否は「操作を実行したか」ではなく「望ましい終了状態に到達しているか」で決める。これが reconciliation の核心である。

ただし切替は本番影響のある不可逆操作であるため、「未実行なのに成功扱い」にならないよう判定は厳密に行う。判定が曖昧な場合は失敗側に倒す。

### Step 7: cleanup — 部分完了で「成功」を返す実害がある

良く書けている部分もある（Deployment 無し → `exit 0`、削除保護 → `exit 1`、`SWITCHOVER_COMPLETED` の確認）。問題は**2 つの削除が非アトミック**な点にある。

```bash
aws ... rds delete-blue-green-deployment ...   # ① 成功
aws ... rds delete-db-instance ...             # ② ここで失敗したら？
```

**① 成功・② 失敗で中断した後に再実行すると、「Deployment 無し」→「既にクリーンアップ済み」で `exit 0` を返す。旧 Blue は削除されず課金が続いているのに、成功と報告する。**

もう 1 点、最終スナップショット名がタイムスタンプ由来である。

```bash
final_snapshot_id="${source_id}-final-$(date -u +%Y%m%d%H%M%S)"
```

再実行のたびに別名になるため、リトライで複数のスナップショットが作られうる。`build_green.sh` が `protection_snapshot_identifier` を固定名で持ち存在確認できるのと対照的である。

**あるべき姿**: 望ましい終了状態を「Deployment が存在せず、**かつ**旧 Blue が存在しない」と定義し、**リソースごとに独立して判定する。**

| リソース | 現在地と動作 |
|---|---|
| Deployment | 存在する → 削除 / `DELETING` → 待つ / 無い → 何もしない |
| 旧 Blue | 存在する → 削除 / `deleting` → 待つ / 無い → 何もしない |

両方が「無い」に到達した時点で `exit 0` とする。

**基準**: 複数リソースを扱うフェーズでは、**片方の完了を全体の完了とみなさない。**

## 横断的な論点

### exit code の意味を統一する

reconciliation 型では次の意味づけが正しい。**現状は switchover だけがこれに反している。**

| code | 意味 |
|---|---|
| `0` | 望ましい状態に到達している（実行したかは問わない） |
| `1` | 到達しておらず、自動では到達できない |

### `pending` / `approved` は冪等性とは別の軸である

承認宣言は**認可**のゲートであり、状態のゲートではない。現行実装はこれを正しく分離できている（`approved` → `pending` に戻しても適用済みを取り消さない）。冪等性を改善する際にこの分離を崩さないこと。

### 同時実行（TOCTOU）

`describe` して「無い」と判定してから `create` するまでの間に、別プロセスが作成する余地がある。RDS 側が同一 source に対する重複作成を弾く可能性が高いが、**未検証である。** 厳密に防ぐなら CI 側でジョブの同時実行を抑止する（GitHub Actions の `concurrency`、CodePipeline の実行モード）ほうが確実である。

## 未検証の前提

いずれも AWS 環境がないため検証していない。実装前に確認する。

**① 切替後の Deployment 解決**
`cleanup.sh` は、切替後も `describe-blue-green-deployments --filters Name=source,Values=<新 Blue の ARN>` で Deployment を引けることを前提にしている。切替時に旧 Blue が `-old1` へリネームされるため、これは **Deployment の `Source` フィールドが作成時の ARN 文字列を保持し続けるか**に依存する。**この前提が崩れると cleanup は対象を見つけられない。**

なお、バージョン ＋ PG による結果の観測を導入すると、switchover についてはこの前提から独立する。Deployment を引けなくても完了を判定できるためである。

**② 切替中のリネームのタイミング**
`SWITCHOVER_IN_PROGRESS` の間、`<source_id>` がまだ旧 Blue（8.0）を指していることを前提にしている。リネームが切替処理のどの時点で行われるかによっては、進行中に `<source_id>` が既に green を指す可能性がある。その場合でも「8.4 ＋ 新 PG なら完了扱い」の判定は結果として安全側に倒れる（実行中に再度 API を呼ばない）が、完了前に成功を返すことになる。`Status` を併用する設計であればこの曖昧さは吸収できる。

## 着手順

| 順 | 対象 | 状態 | 理由 |
|---|---|---|---|
| 1 | `source_engine_version` / `source_db_parameter_group_name` を config へ追加 | **実装済み** | 以降の判定の前提。単独では挙動を変えないため先に入れられる |
| 2 | Step 5 をバージョン ＋ PG の結果判定へ切り替え | **実装済み** | 冪等性の欠如が最も明確で、CI のリトライで顕在化する |
| 3 | Step 7 のリソース別判定 | **実装済み** | 部分完了を成功と報告する実害がある |
| 4 | Step 3 のフェーズガードと状態別分岐 | **実装済み** | サイレント失敗を止める |
| 5 | exit code の意味の統一 | **実装済み** | 上記の前提として整理する |
| 6 | Step 1 の鮮度管理、Step 4 の証跡一意化 | 未着手 | 冪等性そのものではないが同じ文脈で扱える |

### 実装の要点

- 判定関数は `scripts/lib/migration_phase.sh` に切り出し、Step 3・5・7 から `source` して共用する
  - 追記（2026-09-24）: 判定の実装は `scripts/lib/migration_phase.rb` へ移し、`migration_phase.sh` は廃止した。シェルの呼び出し側は `ruby scripts/lib/migration_phase.rb resolve ...` を直接呼ぶ。Ruby スクリプトからは `require_relative` で同じ実装を使える。実装が 1 本なので、シェルと Ruby で判定がずれることはない
- テーブル駆動テスト `tests/migration_phase_test.sh` を用意した。AWS へ接続しないため単体で実行できる。**このテストが実装中に前方一致の破綻を検出した**（上述）
- Step 5 は切替完了まで待つようにした。`exit 0` が「望ましい終了状態に到達した」ことを意味するようにするためである
- Step 3 の `PROVISIONING` 待機は明示的なポーリングで実装した。**AWS CLI に Blue/Green 用の waiter は存在しない**（RDS の waiter は `DBInstanceAvailable` / `DBSnapshotAvailable` など DB インスタンスとスナップショット系のみ）
- Step 7 は最終スナップショット名を `final_snapshot_identifier` として config 化した。タイムスタンプ由来の名前は再実行で別名になり、スナップショットが増殖するためである
- Step 7 は旧 Blue の削除を Deployment の削除より先に行う。逆順だと、Deployment だけ消えて旧 Blue が残った場合に「切替が完了したか」の手がかりが減るためである（フェーズ判定で代替はできる）

**1 は挙動を変えない追加であり、単独で先行できる。** 既存スクリプトは未知のキーを無視するため、config に足しても現行の動作に影響しない。値の正しさ（実際の blue の PG 名と一致しているか）を先に確定させておくと、2 以降の実装と検証が分離できる。

2〜4 は「結果の観測 ＋ 状態機械」という同一の枠組みの適用であり、まとめて実施できる。判定ロジックが増えるため、[structure-review-proposal.md](structure-review-proposal.md) 論点 2（判定のテーブル駆動テスト）と併せて進めるのが望ましい。バージョン ＋ PG と `Status` の組み合わせは分岐が増えるため、テーブル駆動テストの対象として適している。

## 関連ドキュメント

- [structure-review-proposal.md](structure-review-proposal.md) — 論点 2（判定ロジックのテスト）、論点 7（内部処理スクリプトの迂回経路）
- [upgrade-flow-steps.md](../upgrade-flow-steps.md) — 「宣言と実環境の突き合わせ」の節に現行の振る舞い表がある
