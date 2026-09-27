package prereqs

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"rds-mysql-upgrade/tools/internal/mysqlcli"
)

// 成立条件チェックの MySQL 側（collect_blue_mysql_state / collect_blue_upgrade_check）の
// 収集結果を、判定とレポートへ反映する。どちらも任意の収集なので、**ファイルが無ければ
// 該当項目を REVIEW（未収集）とし、レポートの節は省略したことと取得方法を明示する。**
//
//	0-1-06 外部 binlog レプリカ   SHOW REPLICA STATUS が空なら PASS、行があれば STOP
//	0-1-02 binlog_format          実効値がパラメータグループの値と違えば REVIEW（両方を示す）
//	0-2    InnoDB 以外のテーブル  無ければ PASS、MyISAM があれば STOP、他のエンジンだけなら REVIEW
//	0-3    アップグレードチェッカー Error があれば STOP、Warning があれば REVIEW、無ければ PASS

// mysqlSide は MySQL 側の収集結果である（ファイルが無ければ nil）。
type mysqlSide struct {
	State        map[string]any // blue-mysql-state.json
	UpgradeCheck map[string]any // blue-upgrade-check.json
}

func readOptional(dir, name string) (map[string]any, error) {
	content, err := os.ReadFile(filepath.Join(dir, name))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return decode(content, name)
}

func readMySQLSide(dir string) (mysqlSide, error) {
	var side mysqlSide
	var err error
	if side.State, err = readOptional(dir, mysqlcli.StateFileName); err != nil {
		return side, err
	}
	side.UpgradeCheck, err = readOptional(dir, mysqlcli.UpgradeCheckFileName)
	return side, err
}

func presence(document map[string]any) string {
	if document == nil {
		return "省略"
	}
	return "あり"
}

// summaryLine は標準出力の一覧に添える 1 行である。
func (side mysqlSide) summaryLine() string {
	return fmt.Sprintf("MySQL 側の収集: %s=%s, %s=%s", mysqlcli.StateFileName, presence(side.State),
		mysqlcli.UpgradeCheckFileName, presence(side.UpgradeCheck))
}

// ---------------------------------------------------------------------------
// 判定
// ---------------------------------------------------------------------------

const notCollectedState = "未収集。`collect_blue_mysql_state` を実行すると自動で判定できる"

// replicaResult は 0-1-06（外部 binlog レプリカ）の判定である。
func (side mysqlSide) replicaResult() Result {
	item := "0-1-06 外部 binlog レプリカ"
	if side.State == nil {
		return Result{"REVIEW", item, "AWS API では判定できない。" + notCollectedState + "（手で確かめる場合は SHOW REPLICA STATUS\\G が空であること）", "手動確認（" + mysqlcli.StateFileName + " なし）"}
	}
	replicas := list(side.State, "replica_status")
	if len(replicas) == 0 {
		return Result{"PASS", item, "SHOW REPLICA STATUS が空（外部からのレプリカではない）", mysqlcli.StateFileName}
	}
	var sources []string
	for _, entry := range replicas {
		row := object(entry)
		sources = append(sources, text(row["Source_Host"])+":"+text(row["Source_Port"]))
	}
	return Result{"STOP", item, fmt.Sprintf("SHOW REPLICA STATUS が %d 行（接続元 %s）。外部 binlog レプリカである", len(replicas), strings.Join(sources, ", ")), mysqlcli.StateFileName}
}

// binlogEffective は binlog_format の実効値（無ければ空）である。
func (side mysqlSide) binlogEffective() string {
	if side.State == nil {
		return ""
	}
	return text(side.State["binlog_format"])
}

// engineResult は 0-2（InnoDB 以外のテーブル）の判定である。
func (side mysqlSide) engineResult() Result {
	item := "0-2 InnoDB 以外のテーブル"
	if side.State == nil {
		return Result{"REVIEW", item, notCollectedState, "手動確認（" + mysqlcli.StateFileName + " なし）"}
	}
	tables := list(side.State, "non_innodb_tables")
	if len(tables) == 0 {
		return Result{"PASS", item, "ユーザースキーマに InnoDB 以外のテーブルなし", mysqlcli.StateFileName}
	}
	engines := map[string]int{}
	for _, entry := range tables {
		engines[text(object(entry)["ENGINE"])]++
	}
	var counts []string
	for _, engine := range sortedKeys(engines) {
		counts = append(counts, fmt.Sprintf("%s=%d", engine, engines[engine]))
	}
	status := "REVIEW"
	if engines["MyISAM"] > 0 {
		status = "STOP"
	}
	return Result{status, item, fmt.Sprintf("%d 件（%s）。一覧は「MySQL 側の収集結果」", len(tables), strings.Join(counts, ", ")), mysqlcli.StateFileName}
}

// checkerResult は 0-3（MySQL Shell アップグレードチェッカー）の判定である。
func (side mysqlSide) checkerResult() Result {
	item := "0-3 アップグレードチェッカー"
	if side.UpgradeCheck == nil {
		return Result{"REVIEW", item, "未収集。`collect_blue_upgrade_check`（スナップショット復元機に対して）を実行すると自動で判定できる", "手動確認（" + mysqlcli.UpgradeCheckFileName + " なし）"}
	}
	u := side.UpgradeCheck
	detail := fmt.Sprintf("Error=%s / Warning=%s / Notice=%s（target=%s）", text(u["error_count"]), text(u["warning_count"]), text(u["notice_count"]), text(u["target_version"]))
	errors, _ := number(u["error_count"])
	warnings, _ := number(u["warning_count"])
	switch {
	case errors > 0:
		return Result{"STOP", item, detail, mysqlcli.UpgradeCheckFileName}
	case warnings > 0:
		return Result{"REVIEW", item, detail + "。Warning は個別に判断する", mysqlcli.UpgradeCheckFileName}
	}
	return Result{"PASS", item, detail, mysqlcli.UpgradeCheckFileName}
}

func sortedKeys(values map[string]int) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// ---------------------------------------------------------------------------
// レポート
// ---------------------------------------------------------------------------

func omitted(file, command string) []string {
	return []string{
		fmt.Sprintf("**省略した。**入力ディレクトリに `%s` が無い（`%s` を実行していない）。この節に関わる項目は REVIEW（未収集）として判定した。", file, command),
		"",
	}
}

// reportLines は「MySQL 側の収集結果」節の行である。
func (side mysqlSide) reportLines() []string {
	lines := []string{
		"## MySQL 側の収集結果",
		"",
		"Blue へ接続して集めた、AWS API では見えない情報である。0-1-06・0-2・0-3 の判定と、0-1-02 の実効値の確認に使った。",
		"",
		"### 接続先の状態（`" + mysqlcli.StateFileName + "`）",
		"",
	}
	if side.State == nil {
		lines = append(lines, omitted(mysqlcli.StateFileName, "collect_blue_mysql_state")...)
	} else {
		lines = append(lines, side.stateLines()...)
	}
	lines = append(lines, "### MySQL Shell アップグレードチェッカー（`"+mysqlcli.UpgradeCheckFileName+"`）", "")
	if side.UpgradeCheck == nil {
		lines = append(lines, omitted(mysqlcli.UpgradeCheckFileName, "collect_blue_upgrade_check")...)
	} else {
		lines = append(lines, side.upgradeCheckLines()...)
	}
	return lines
}

// referenceVariables は「主要なサーバー変数」に並べる変数と、見る理由である。
// 判定には使わない（判定に使うのは binlog_format だけ）。移行の前後で比べる基準値として残す。
var referenceVariables = []struct{ name, note string }{
	{"version_comment", "ディストリビューション"},
	{"log_bin", "Blue/Green はバイナリログでレプリケーションする（RDS では自動バックアップが有効なら ON）"},
	{"binlog_format", "0-1-02。パラメータグループの値との食い違いを見る"},
	{"binlog_row_image", "ROW 形式時の出力量"},
	{"gtid_mode", "参考。Blue/Green は GTID を要求しない"},
	{"enforce_gtid_consistency", "参考"},
	{"default_authentication_plugin", "8.4 で削除される（authentication_policy へ移る）"},
	{"authentication_policy", "8.4 での認証方式の決め方"},
	{"character_set_server", "8.4 で既定は変わらない。アプリの接続設定との整合"},
	{"collation_server", "同上"},
	{"time_zone", "時刻の扱い（docs/references/mysql-timezone.md）"},
	{"system_time_zone", "同上"},
	{"sql_mode", "8.4 で既定は変わらない。明示値の確認"},
	{"lower_case_table_names", "初期化後に変更できない"},
	{"transaction_isolation", "参考"},
	{"explicit_defaults_for_timestamp", "参考"},
	{"default_storage_engine", "0-2 に関連"},
	{"innodb_default_row_format", "参考"},
	{"read_only", "Blue は書き込み可能であること"},
	{"max_connections", "参考"},
}

func (side mysqlSide) variables() map[string]any {
	if side.State == nil {
		return nil
	}
	return object(side.State["variables"])
}

func (side mysqlSide) stateLines() []string {
	s := side.State
	replicas := list(s, "replica_status")
	tables := list(s, "non_innodb_tables")
	variables := side.variables()
	lines := []string{
		"| 項目 | 値 |",
		"|---|---|",
		"| 収集日時 | " + escapeCell(text(s["collected_at"])) + " |",
		"| 接続先 | `" + escapeCell(text(s["host"])) + ":" + escapeCell(text(s["port"])) + "` |",
		"| MySQL バージョン | " + escapeCell(text(s["version"])) + " |",
		"| binlog_format（実効値） | " + escapeCell(text(s["binlog_format"])) + " |",
		fmt.Sprintf("| SHOW REPLICA STATUS | %d 行 |", len(replicas)),
		fmt.Sprintf("| InnoDB 以外のテーブル | %d 件 |", len(tables)),
		fmt.Sprintf("| サーバー変数（SHOW GLOBAL VARIABLES） | %d 件 |", len(variables)),
		"",
	}

	lines = append(lines, "**主要なサーバー変数**（判定には使わない。移行の前後で比べる基準値。全件は JSON の `variables`）", "")
	if variables == nil {
		lines = append(lines, "未収集（この収集結果にはサーバー変数が無い。`collect_blue_mysql_state` を再実行すると載る）。", "")
	} else {
		lines = append(lines, "| 変数 | 値 | 見る理由 |", "|---|---|---|")
		for _, v := range referenceVariables {
			value, ok := variables[v.name]
			shown := "`" + escapeCell(text(value)) + "`"
			if !ok {
				shown = "（この版には無い）"
			} else if text(value) == "" {
				shown = "（空）"
			}
			lines = append(lines, "| "+v.name+" | "+shown+" | "+escapeCell(v.note)+" |")
		}
		lines = append(lines, "")
	}

	lines = append(lines, "**SHOW REPLICA STATUS**（0-1-06。空なら Blue は外部からのレプリカではない）", "")
	if len(replicas) == 0 {
		lines = append(lines, "空（レプリケーションの受け側になっていない）。", "")
	} else {
		// 判断に使う列を先に要約し、続けてチャネルごとに全列を載せる。
		columns := []string{"Channel_Name", "Source_Host", "Source_Port", "Replica_IO_Running", "Replica_SQL_Running",
			"Seconds_Behind_Source", "Last_IO_Error", "Last_SQL_Error"}
		lines = append(lines, "| "+strings.Join(columns, " | ")+" |", "|"+strings.Repeat("---|", len(columns)))
		for _, entry := range replicas {
			row := object(entry)
			cells := make([]string, len(columns))
			for i, column := range columns {
				cells[i] = escapeCell(text(row[column]))
			}
			lines = append(lines, "| "+strings.Join(cells, " | ")+" |")
		}
		lines = append(lines, "", "外部 binlog レプリカは Blue/Green の前提を満たさない。構成を解消するか、移行方式を再検討する。", "")
		for i, entry := range replicas {
			row := object(entry)
			lines = append(lines, fmt.Sprintf("<details><summary>%d 行目の全列（チャネル `%s`）</summary>", i+1, text(row["Channel_Name"])), "",
				"| 列 | 値 |", "|---|---|")
			for _, column := range sortedAnyKeys(row) {
				lines = append(lines, "| "+escapeCell(column)+" | "+escapeCell(text(row[column]))+" |")
			}
			lines = append(lines, "", "</details>", "")
		}
	}

	lines = append(lines, "**InnoDB 以外のテーブル**（0-2。ユーザースキーマのみ。MyISAM は binlog レプリケーションで整合性が保証されない）", "")
	if len(tables) == 0 {
		lines = append(lines, "なし。", "")
	} else {
		lines = append(lines, "| スキーマ | テーブル | エンジン | 行形式 | 行数（概算） | データ | インデックス | 作成 | 最終更新 | 対処の例 |",
			"|---|---|---|---|---|---|---|---|---|---|")
		var total float64
		for _, entry := range tables {
			row := object(entry)
			schema, table, engine := text(row["TABLE_SCHEMA"]), text(row["TABLE_NAME"]), text(row["ENGINE"])
			action := "用途を確認する"
			if engine == "MyISAM" {
				action = "`ALTER TABLE " + schema + "." + table + " ENGINE=InnoDB`"
			}
			data, index := bytesOf(row["DATA_LENGTH"]), bytesOf(row["INDEX_LENGTH"])
			total += data + index
			lines = append(lines, "| "+strings.Join([]string{escapeCell(schema), escapeCell(table), escapeCell(engine),
				escapeCell(orDash(row["ROW_FORMAT"])), escapeCell(orDash(row["TABLE_ROWS"])),
				sizeOrDash(row["DATA_LENGTH"]), sizeOrDash(row["INDEX_LENGTH"]),
				escapeCell(orDash(row["CREATE_TIME"])), escapeCell(orDash(row["UPDATE_TIME"])), escapeCell(action)}, " | ")+" |")
		}
		lines = append(lines, "", fmt.Sprintf("合計サイズ（データ＋インデックス）: %s。InnoDB への変換はテーブルを作り直すため、この量に比例して時間がかかる。", humanBytes(total)), "")
	}
	return lines
}

func (side mysqlSide) upgradeCheckLines() []string {
	u := side.UpgradeCheck
	report := object(u["report"])
	lines := []string{
		"| 項目 | 値 |",
		"|---|---|",
		"| 収集日時 | " + escapeCell(text(u["collected_at"])) + " |",
		"| 接続先 | `" + escapeCell(text(u["host"])) + ":" + escapeCell(text(u["port"])) + "` |",
		"| チェッカーが見た接続先 | `" + escapeCell(text(report["serverAddress"])) + "` |",
		"| サーバー | " + escapeCell(text(report["serverVersion"])) + " |",
		"| 移行先バージョン | " + escapeCell(text(u["target_version"])) + " |",
		"| Error / Warning / Notice | " + text(u["error_count"]) + " / " + text(u["warning_count"]) + " / " + text(u["notice_count"]) + " |",
		"| mysqlsh の終了コード | " + text(u["shell_exit_code"]) + " |",
		"| 要約 | " + escapeCell(text(report["summary"])) + " |",
		"",
	}

	checks := list(report, "checksPerformed")
	lines = append(lines, "**検査項目**", "", "| 検査 | 状態 | Error | Warning | Notice |", "|---|---|---|---|---|")
	type problem struct{ level, check, objectType, object, description string }
	var problems []problem
	for _, entry := range checks {
		check := object(entry)
		levels := map[string]int{}
		for _, found := range list(check, "detectedProblems") {
			p := object(found)
			levels[text(p["level"])]++
			problems = append(problems, problem{text(p["level"]), text(check["id"]), text(p["dbObjectType"]), text(p["dbObject"]), text(p["description"])})
		}
		lines = append(lines, fmt.Sprintf("| %s（`%s`） | %s | %d | %d | %d |",
			escapeCell(text(check["title"])), escapeCell(text(check["id"])), escapeCell(text(check["status"])),
			levels["Error"], levels["Warning"], levels["Notice"]))
	}
	lines = append(lines, "")

	// 既定値が変わる変数は、Blue の現在値を並べると影響の有無が読める。
	variables := side.variables()
	lines = append(lines, "**検出された問題**（Error を先に並べる。内容はチェッカーの出力のまま）", "")
	if len(problems) == 0 {
		lines = append(lines, "なし。", "")
	} else {
		rank := map[string]int{"Error": 0, "Warning": 1, "Notice": 2}
		sort.SliceStable(problems, func(i, j int) bool { return rank[problems[i].level] < rank[problems[j].level] })
		lines = append(lines, "| レベル | 検査 | 種別 | 対象 | 内容 | Blue の現在値 |", "|---|---|---|---|---|---|")
		for _, p := range problems {
			current := "—"
			if p.objectType == "SystemVariable" {
				if variables == nil {
					current = "未収集"
				} else if value, ok := variables[p.object]; ok {
					current = "`" + escapeCell(text(value)) + "`"
				} else {
					current = "（変数なし）"
				}
			}
			lines = append(lines, "| "+strings.Join([]string{escapeCell(p.level), "`" + escapeCell(p.check) + "`", escapeCell(p.objectType),
				escapeCell(p.object), escapeCell(p.description), current}, " | ")+" |")
		}
		lines = append(lines, "")
		if variables != nil {
			lines = append(lines, "「既定値が変わる」変数は、パラメータグループで値を明示していなければ 8.4 で新しい既定値になる。Blue の現在値を 8.4 でも保ちたい場合は、Step 2 のパラメータグループに明示する。", "")
		}
	}

	// すべての検査について、チェッカー自身の説明・対処・資料を載せる（英語のまま）。
	lines = append(lines, "**各検査の説明と対処**（チェッカーが返した内容。英語のまま載せる）", "")
	for _, entry := range checks {
		check := object(entry)
		lines = append(lines, fmt.Sprintf("- **%s**（`%s`。状態 %s、検出 %d 件）", text(check["title"]), text(check["id"]),
			text(check["status"]), len(list(check, "detectedProblems"))))
		lines = append(lines, checkDetails(check)...)
	}
	lines = append(lines, "")

	manual := list(report, "manualChecks")
	lines = append(lines, "**手動確認が要る項目**（チェッカーが自動では判定しないもの）", "")
	if len(manual) == 0 {
		lines = append(lines, "なし。", "")
	} else {
		for _, entry := range manual {
			check := object(entry)
			lines = append(lines, "- **"+text(check["title"])+"**（`"+text(check["id"])+"`）")
			lines = append(lines, checkDetails(check)...)
		}
		lines = append(lines, "")
	}
	return lines
}

// checkDetails はチェッカーの検査 1 件の説明・対処・資料を箇条書きの子要素にする。
func checkDetails(check map[string]any) []string {
	var lines []string
	if description := text(check["description"]); description != "" {
		lines = append(lines, "  - 説明: "+oneLine(description))
	}
	for _, solution := range list(check, "solutions") {
		lines = append(lines, "  - 対処: "+oneLine(text(solution)))
	}
	if link := text(check["documentationLink"]); link != "" {
		lines = append(lines, "  - 資料: "+link)
	}
	if len(lines) == 0 {
		lines = append(lines, "  - （説明・対処の記載なし）")
	}
	return lines
}

func sortedAnyKeys(values map[string]any) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func orDash(value any) string {
	if s := text(value); s != "" {
		return s
	}
	return "—"
}

func bytesOf(value any) float64 {
	if n, ok := number(value); ok {
		return n
	}
	f, err := strconv.ParseFloat(text(value), 64)
	if err != nil {
		return 0
	}
	return f
}

func sizeOrDash(value any) string {
	if text(value) == "" {
		return "—"
	}
	return humanBytes(bytesOf(value))
}

// humanBytes はバイト数を読みやすい単位にする（1024 基準）。
func humanBytes(value float64) string {
	units := []string{"B", "KiB", "MiB", "GiB", "TiB"}
	i := 0
	for value >= 1024 && i < len(units)-1 {
		value /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f %s", value, units[i])
	}
	return fmt.Sprintf("%.1f %s", value, units[i])
}

func oneLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

// ---------------------------------------------------------------------------
// 補足事項
// ---------------------------------------------------------------------------

// notes はレポート末尾の「補足事項」である。収集の網羅状況・時点・接続先と、
// 判定の前提として知っておくべきことを並べる。
func (e *Evaluation) notes() []string {
	side := e.MySQL
	lines := []string{
		"## 補足事項",
		"",
		"### 収集の網羅状況",
		"",
		"| 収集 | コマンド | 状態 | 収集日時 |",
		"|---|---|---|---|",
		"| AWS 側 | `collect_blue_green_prereqs` | あり | " + escapeCell(text(e.Metadata["collected_at"])) + " |",
		"| 接続先の状態 | `collect_blue_mysql_state` | " + presence(side.State) + " | " + escapeCell(textOf(side.State, "collected_at")) + " |",
		"| アップグレードチェッカー | `collect_blue_upgrade_check` | " + presence(side.UpgradeCheck) + " | " + escapeCell(textOf(side.UpgradeCheck, "collected_at")) + " |",
		"",
	}

	var remarks []string
	if side.State == nil || side.UpgradeCheck == nil {
		remarks = append(remarks, "MySQL 側の収集が欠けている。欠けた収集に関わる項目（0-1-06・0-2・0-3）は REVIEW（未収集）として判定している。収集してから再判定すると自動で PASS / STOP が決まる")
	}
	// 収集時点の差。時間が空くと、AWS 側と MySQL 側で別の状態を見ている可能性がある。
	if gap, ok := collectionGap(e.Metadata, side); ok && gap > 24*time.Hour {
		remarks = append(remarks, fmt.Sprintf("AWS 側と MySQL 側の収集日時が %.0f 時間以上離れている。同じ時点の状態として扱う前に再収集を検討する", gap.Hours()))
	}
	// 接続先の確認。チェッカーはスナップショット復元機で動かす想定なので、Blue と違って構わない。
	if side.State != nil && e.Endpoint != "" && text(side.State["host"]) != e.Endpoint {
		remarks = append(remarks, "`"+mysqlcli.StateFileName+"` の接続先（`"+text(side.State["host"])+"`）が対象 Blue のエンドポイント（`"+e.Endpoint+"`）と違う。0-1-06・0-2 は Blue 本体の状態であるべきなので、接続先を確認する")
	}
	if side.UpgradeCheck != nil && e.Endpoint != "" && text(side.UpgradeCheck["host"]) == e.Endpoint {
		remarks = append(remarks, "アップグレードチェッカーを対象 Blue（本番）に対して実行している。メタデータの全走査が走るため、移行ガイドの 0-3 はスナップショット復元機での実行を推奨している")
	}
	if effective, declared := side.binlogEffective(), e.binlogDeclared; effective != "" && declared != "" && effective != declared {
		remarks = append(remarks, "binlog_format の実効値（"+effective+"）がパラメータグループの値（"+declared+"）と違う。適用待ち（再起動）や上書きの有無を確認する")
	}
	remarks = append(remarks,
		"MySQL Shell のアップグレードチェッカーと RDS 組み込みのプリチェックは検査項目が一致しない。RDS 固有の項目（FLOAT / DOUBLE の AUTO_INCREMENT、非包摂的用語、memcached、空き容量、sys スキーマ）は Shell では出ないため、スナップショット復元機で試験アップグレードを 1 回通し `PrePatchCompatibility.log` を確認する",
		"このチェックは Blue/Green を**作成できるか**を見るものである。アプリケーションの互換性（実行 SQL・クライアントライブラリ）は移行ガイドの 0-4・0-5 で別に確認する",
	)
	lines = append(lines, "### 注意点", "")
	for _, remark := range remarks {
		lines = append(lines, "- "+remark)
	}
	lines = append(lines, "")

	lines = append(lines, "### 項目ごとの補足", "", "| 判定 | 項目 | 合格条件 | 満たさないときの対処 | 参照 |", "|---|---|---|---|---|")
	for _, result := range e.Results {
		key := strings.Fields(result.Item)[0]
		g := guidanceByItem[key]
		lines = append(lines, "| "+result.Status+" | "+escapeCell(result.Item)+" | "+escapeCell(g.Condition)+" | "+escapeCell(g.Action)+" | `"+escapeCell(g.Reference)+"` |")
	}
	lines = append(lines, "")
	return lines
}

func textOf(document map[string]any, key string) string {
	if document == nil {
		return "—"
	}
	return text(document[key])
}

// collectionGap は AWS 側と MySQL 側の収集日時のうち、最も離れた差を返す。
func collectionGap(metadata map[string]any, side mysqlSide) (time.Duration, bool) {
	base, err := time.Parse(time.RFC3339, text(metadata["collected_at"]))
	if err != nil {
		return 0, false
	}
	var gap time.Duration
	found := false
	for _, document := range []map[string]any{side.State, side.UpgradeCheck} {
		if document == nil {
			continue
		}
		at, err := time.Parse(time.RFC3339, text(document["collected_at"]))
		if err != nil {
			continue
		}
		difference := at.Sub(base)
		if difference < 0 {
			difference = -difference
		}
		if difference > gap {
			gap = difference
		}
		found = true
	}
	return gap, found
}
