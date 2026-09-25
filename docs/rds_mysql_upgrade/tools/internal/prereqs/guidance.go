package prereqs

// guidance は各チェック項目の補足（合格条件・満たさないときの対処・参照）である。
// 正本は docs/phase-0-precheck.md のチェックリストと docs/rds-mysql-84-migration-guide.md の
// Phase 0（0-2・0-3）で、レポートの「項目ごとの補足」に載せる。**文言を変えるときは正本と揃える。**
type guidance struct {
	Condition string // 合格条件
	Action    string // 満たさないときの対処
	Reference string // 参照
}

const (
	precheckDoc = "docs/phase-0-precheck.md"
	guideDoc    = "docs/rds-mysql-84-migration-guide.md"
)

// guidanceByItem は項目番号（Result.Item の先頭の語）から補足を引く。
var guidanceByItem = map[string]guidance{
	"0-1-01": {"`BackupRetentionPeriod` が 1 以上", "自動バックアップを有効化し、設定が反映されるまで待つ", precheckDoc},
	"0-1-02": {"値を記録する（Blue/Green の作成に `ROW` は必須ではない）",
		"Blue を `ROW` に統一する場合は、移行と分離した運用判断として扱う。パラメータグループの値と実効値が違えば、適用待ち（再起動）や上書きの有無を確認する",
		"docs/decisions/binlog-format-bluegreen-compatibility.md"},
	"0-1-03": {"メジャーアップグレードの Blue/Green で使えるデフォルトのオプショングループ",
		"カスタムグループを使っている場合は、デフォルトへ戻す影響を確認・解消する", precheckDoc},
	"0-1-04": {"`MEMCACHED` が無い", "利用停止・アプリ設定変更・オプショングループ変更を先に完了する（memcached は 8.3 で廃止）", precheckDoc},
	"0-1-05": {"`ParameterApplyStatus` が `in-sync`", "`pending-reboot` 等なら、必要なパラメータ反映（再起動）を完了する", precheckDoc},
	"0-1-06": {"`SHOW REPLICA STATUS` が空（Blue が外部からの binlog レプリカではない）",
		"外部レプリカの場合は構成を解消するか、移行方式を再検討する。未収集なら `collect_blue_mysql_state` で取得するか手で `SHOW REPLICA STATUS\\G` を確認する", precheckDoc},
	"0-1-07": {"カスケード構成（レプリカの配下のレプリカ）が無い", "該当する場合は構成を解消する", precheckDoc},
	"0-1-08": {"MySQL 8.4 を作成できる current / latest-generation のクラス", "前世代クラスは、Blue/Green 作成前にクラス変更を完了する", precheckDoc},
	"0-1-09": {"アップグレード・検証中に逼迫しない空き容量（目安 2 GiB 以上）", "不足時は空き容量を確保する。メトリクスが無ければ CloudWatch で直近の値を確認する", precheckDoc},
	"0-1-10": {"利用していない、または Blue/Green の制約と一時解除・再設定の手順を確認済み", "Secrets Manager 管理パスワードの制約を確認し、手順を用意する", precheckDoc},
	"0-1-11": {"利用していない、または Blue/Green の制約と一時解除・再設定の手順を確認済み", "Zero-ETL 統合の制約を確認し、手順を用意する", precheckDoc},
	"0-1-12": {"利用していない、または Blue/Green の制約と一時解除・再設定の手順を確認済み", "クロスリージョンリードレプリカの扱いを確認し、手順を用意する", precheckDoc},
	"0-1-13": {"Proxy が無い、または Blue が事前に対象 Proxy へ登録済み", "Blue/Green 作成後は新規登録できないため、作成前に登録し、制約を関係者と共有する", precheckDoc},
	"0-1-14": {"無効、または切替後の Green 用 DB リソース ID / ARN を IAM ポリシーへ追加する手順と権限が準備済み", "IAM ポリシーの更新手順を用意する", precheckDoc},
	"0-2": {"ユーザースキーマに InnoDB 以外のテーブルが無い（`mysql` スキーマのシステムテーブルは対象外）",
		"MyISAM は binlog レプリケーションで整合性が保証されないため `ALTER TABLE <db>.<table> ENGINE=InnoDB` で変換する。それ以外のエンジンは用途を確認する", guideDoc + " の 0-2"},
	"0-3": {"MySQL Shell のアップグレードチェッカーで Error が 0 件（Warning は個別判断）",
		"Error は移行ガイドの対処表に従って解消する。**本番ではなくスナップショット復元機で実行し**、RDS 固有の項目は試験アップグレードの `PrePatchCompatibility.log` で確認する", guideDoc + " の 0-3"},
}
