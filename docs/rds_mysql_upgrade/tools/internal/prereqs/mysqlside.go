package prereqs

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
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

func (side mysqlSide) stateLines() []string {
	s := side.State
	replicas := list(s, "replica_status")
	tables := list(s, "non_innodb_tables")
	lines := []string{
		"| 項目 | 値 |",
		"|---|---|",
		"| 収集日時 | " + escapeCell(text(s["collected_at"])) + " |",
		"| 接続先 | `" + escapeCell(text(s["host"])) + ":" + escapeCell(text(s["port"])) + "` |",
		"| MySQL バージョン | " + escapeCell(text(s["version"])) + " |",
		"| binlog_format（実効値） | " + escapeCell(text(s["binlog_format"])) + " |",
		fmt.Sprintf("| SHOW REPLICA STATUS | %d 行 |", len(replicas)),
		fmt.Sprintf("| InnoDB 以外のテーブル | %d 件 |", len(tables)),
		"",
	}

	lines = append(lines, "**SHOW REPLICA STATUS**（0-1-06。空なら Blue は外部からのレプリカではない）", "")
	if len(replicas) == 0 {
		lines = append(lines, "空（レプリケーションの受け側になっていない）。", "")
	} else {
		// 判断に使う列だけを並べる。全列は JSON に残っている。
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
	}

	lines = append(lines, "**InnoDB 以外のテーブル**（0-2。ユーザースキーマのみ。MyISAM は binlog レプリケーションで整合性が保証されない）", "")
	if len(tables) == 0 {
		lines = append(lines, "なし。", "")
	} else {
		lines = append(lines, "| スキーマ | テーブル | エンジン | 対処の例 |", "|---|---|---|---|")
		for _, entry := range tables {
			row := object(entry)
			schema, table, engine := text(row["TABLE_SCHEMA"]), text(row["TABLE_NAME"]), text(row["ENGINE"])
			action := "用途を確認する"
			if engine == "MyISAM" {
				action = "`ALTER TABLE " + schema + "." + table + " ENGINE=InnoDB`"
			}
			lines = append(lines, "| "+escapeCell(schema)+" | "+escapeCell(table)+" | "+escapeCell(engine)+" | "+escapeCell(action)+" |")
		}
		lines = append(lines, "")
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
		"| サーバー | " + escapeCell(text(report["serverVersion"])) + " |",
		"| 移行先バージョン | " + escapeCell(text(u["target_version"])) + " |",
		"| Error / Warning / Notice | " + text(u["error_count"]) + " / " + text(u["warning_count"]) + " / " + text(u["notice_count"]) + " |",
		"| mysqlsh の終了コード | " + text(u["shell_exit_code"]) + " |",
		"| 要約 | " + escapeCell(text(report["summary"])) + " |",
		"",
	}

	checks := list(report, "checksPerformed")
	lines = append(lines, "**検査項目**", "", "| 検査 | 状態 | 検出件数 |", "|---|---|---|")
	type problem struct{ level, check, object, description string }
	var problems []problem
	var detailed []map[string]any
	for _, entry := range checks {
		check := object(entry)
		detected := list(check, "detectedProblems")
		lines = append(lines, fmt.Sprintf("| %s（`%s`） | %s | %d |",
			escapeCell(text(check["title"])), escapeCell(text(check["id"])), escapeCell(text(check["status"])), len(detected)))
		for _, found := range detected {
			p := object(found)
			problems = append(problems, problem{text(p["level"]), text(check["id"]), text(p["dbObject"]), text(p["description"])})
		}
		if len(detected) > 0 {
			detailed = append(detailed, check)
		}
	}
	lines = append(lines, "")

	lines = append(lines, "**検出された問題**（Error を先に並べる）", "")
	if len(problems) == 0 {
		lines = append(lines, "なし。", "")
	} else {
		rank := map[string]int{"Error": 0, "Warning": 1, "Notice": 2}
		sort.SliceStable(problems, func(i, j int) bool { return rank[problems[i].level] < rank[problems[j].level] })
		lines = append(lines, "| レベル | 検査 | 対象 | 内容 |", "|---|---|---|---|")
		for _, p := range problems {
			lines = append(lines, "| "+escapeCell(p.level)+" | `"+escapeCell(p.check)+"` | "+escapeCell(p.object)+" | "+escapeCell(p.description)+" |")
		}
		lines = append(lines, "")
	}

	// 問題が見つかった検査について、チェッカー自身の説明・対処・資料を載せる。
	if len(detailed) > 0 {
		lines = append(lines, "**検出された検査の説明と対処**（チェッカーが返した内容）", "")
		for _, check := range detailed {
			lines = append(lines, "- **"+text(check["title"])+"**（`"+text(check["id"])+"`）")
			if description := text(check["description"]); description != "" {
				lines = append(lines, "  - 説明: "+oneLine(description))
			}
			for _, solution := range list(check, "solutions") {
				lines = append(lines, "  - 対処: "+oneLine(text(solution)))
			}
			if link := text(check["documentationLink"]); link != "" {
				lines = append(lines, "  - 資料: "+link)
			}
		}
		lines = append(lines, "")
	}

	manual := list(report, "manualChecks")
	lines = append(lines, "**手動確認が要る項目**（チェッカーが自動では判定しないもの）", "")
	if len(manual) == 0 {
		lines = append(lines, "なし。", "")
	} else {
		for _, entry := range manual {
			check := object(entry)
			lines = append(lines, "- "+text(check["title"])+"（`"+text(check["id"])+"`）")
			if description := text(check["description"]); description != "" {
				lines = append(lines, "  - "+oneLine(description))
			}
		}
		lines = append(lines, "")
	}
	return lines
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
