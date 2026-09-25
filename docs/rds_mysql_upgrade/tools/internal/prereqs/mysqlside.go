package prereqs

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"rds-mysql-upgrade/tools/internal/mysqlcli"
)

// 成立条件チェックの MySQL 側（collect_blue_mysql_state / collect_blue_upgrade_check）の
// 収集結果をレポートへ載せる。どちらも任意の収集なので、**ファイルが無ければ節を省略し、
// 省略したことと、どのコマンドで取れるかを明示する。**
//
// ここは結果を並べるだけで、PASS / REVIEW / STOP の判定と終了コードには使わない。

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

func omitted(file, command string) []string {
	return []string{
		fmt.Sprintf("**省略した。**入力ディレクトリに `%s` が無い（`%s` を実行していない）。", file, command),
		"",
	}
}

// reportLines は「MySQL 側の収集結果」節の行である。
func (side mysqlSide) reportLines() []string {
	lines := []string{
		"## MySQL 側の収集結果",
		"",
		"Blue へ接続して集めた、AWS API では見えない情報である。**判定（PASS / REVIEW / STOP）には使っていない。**" +
			"人がここを見て、0-1-06 などの手動確認の根拠にする。",
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

	lines = append(lines, "**SHOW REPLICA STATUS**（0-1-06 外部 binlog レプリカ。空なら Blue はレプリカではない）", "")
	if len(replicas) == 0 {
		lines = append(lines, "空（レプリケーションの受け側になっていない）。", "")
	} else {
		// 判断に使う列だけを並べる。全列は JSON に残っている。
		columns := []string{"Source_Host", "Source_Port", "Replica_IO_Running", "Replica_SQL_Running", "Last_Error"}
		lines = append(lines, "| "+strings.Join(columns, " | ")+" |", "|"+strings.Repeat("---|", len(columns)))
		for _, entry := range replicas {
			row := object(entry)
			cells := make([]string, len(columns))
			for i, column := range columns {
				cells[i] = escapeCell(text(row[column]))
			}
			lines = append(lines, "| "+strings.Join(cells, " | ")+" |")
		}
		lines = append(lines, "")
	}

	lines = append(lines, "**InnoDB 以外のテーブル**（ユーザースキーマ。MyISAM は Blue/Green のレプリケーションで整合性が保証されない）", "")
	if len(tables) == 0 {
		lines = append(lines, "なし。", "")
	} else {
		lines = append(lines, "| スキーマ | テーブル | エンジン |", "|---|---|---|")
		for _, entry := range tables {
			row := object(entry)
			lines = append(lines, "| "+escapeCell(text(row["TABLE_SCHEMA"]))+" | "+escapeCell(text(row["TABLE_NAME"]))+
				" | "+escapeCell(text(row["ENGINE"]))+" |")
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
		"| 要約 | " + escapeCell(text(report["summary"])) + " |",
		"",
	}

	checks := list(report, "checksPerformed")
	lines = append(lines, "**検査項目**", "", "| 検査 | 状態 | 検出件数 |", "|---|---|---|")
	type problem struct{ level, check, object, description string }
	var problems []problem
	for _, entry := range checks {
		check := object(entry)
		detected := list(check, "detectedProblems")
		lines = append(lines, fmt.Sprintf("| %s（`%s`） | %s | %d |",
			escapeCell(text(check["title"])), escapeCell(text(check["id"])), escapeCell(text(check["status"])), len(detected)))
		for _, found := range detected {
			p := object(found)
			problems = append(problems, problem{text(p["level"]), text(check["id"]), text(p["dbObject"]), text(p["description"])})
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

	manual := list(report, "manualChecks")
	if len(manual) > 0 {
		lines = append(lines, "**手動確認が要る項目**（チェッカーが自動では判定しないもの）", "")
		for _, entry := range manual {
			check := object(entry)
			lines = append(lines, "- "+text(check["title"])+"（`"+text(check["id"])+"`）")
		}
		lines = append(lines, "")
	}
	return lines
}
