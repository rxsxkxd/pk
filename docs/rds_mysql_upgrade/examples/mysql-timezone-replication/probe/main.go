// タイムゾーン差異のドライバ検証（Go / go-sql-driver/mysql）— 収集のみ。
//
// 本スクリプトは観測した事実を reports/go.json へ書き出すだけであり、
// 合否の判定とレポート生成は行わない。判定は generate_report.rb が担当する
// （収集と判定を分離するという本リポジトリの方針に合わせている）。
//
// DSN の loc は「サーバーから返る日時文字列をどのロケーションとして解釈するか」を
// 決めるクライアント側の設定であり、サーバーへ SET time_zone は発行しない。
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

const (
	sqlRows   = "SELECT id, ts, UNIX_TIMESTAMP(ts) FROM t ORDER BY id"
	sqlWhere  = "SELECT COUNT(*) FROM t WHERE ts >= '2026-09-03 00:00:00'"
	sqlGroups = "SELECT COUNT(*) FROM (SELECT DATE(ts) FROM t GROUP BY DATE(ts)) g"
)

// ---- 共通 JSON スキーマ（3 言語で同一）----

type ReadResult struct {
	Section     string `json:"section"`
	Detail      string `json:"detail"`
	ID          int    `json:"id"`
	DriverValue string `json:"driver_value"`
	DriverUnix  int64  `json:"driver_unix"`
	ServerUnix  int64  `json:"server_unix"`
}

type Contrast struct {
	Title   string       `json:"title"`
	Results []ReadResult `json:"results"`
}

type ServerSideResult struct {
	Label        string `json:"label"`
	Setting      string `json:"setting"`
	WhereMatched int    `json:"where_matched"`
	DateGroups   int    `json:"date_groups"`
}

type Collection struct {
	SchemaVersion     int                `json:"schema_version"`
	Language          string             `json:"language"`
	Driver            string             `json:"driver"`
	TimezoneLayer     string             `json:"timezone_layer"`
	IssuesSetTimeZone bool               `json:"issues_set_time_zone"`
	SettingLabel      string             `json:"setting_label"`
	CollectedAt       string             `json:"collected_at"`
	ReadResults       []ReadResult       `json:"read_results"`
	Contrast          Contrast           `json:"contrast"`
	ServerSide        []ServerSideResult `json:"server_side"`
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func dsn(host, loc string) string {
	return fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&loc=%s",
		env("MYSQL_USER", "root"), os.Getenv("MYSQL_PWD"), host,
		env("MYSQL_PORT", "3306"), env("MYSQL_DATABASE", "tzcheck"), loc)
}

// 読み取り値をドライバがどう解釈したかを収集する。
func collectRead(label, host, loc string) ([]ReadResult, error) {
	db, err := sql.Open("mysql", dsn(host, loc))
	if err != nil {
		return nil, err
	}
	defer db.Close()

	var sessionTZ string
	if err := db.QueryRow("SELECT @@session.time_zone").Scan(&sessionTZ); err != nil {
		return nil, err
	}
	section := fmt.Sprintf("%s / loc=%s", label, loc)
	detail := fmt.Sprintf("session_time_zone=%s", sessionTZ)

	rows, err := db.Query(sqlRows)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ReadResult
	for rows.Next() {
		var id int
		var ts time.Time
		var serverEpoch int64
		if err := rows.Scan(&id, &ts, &serverEpoch); err != nil {
			return nil, err
		}
		out = append(out, ReadResult{
			Section: section, Detail: detail, ID: id,
			DriverValue: ts.Format("2006-01-02 15:04:05 -0700"),
			DriverUnix:  ts.Unix(), ServerUnix: serverEpoch,
		})
	}
	return out, rows.Err()
}

// サーバー側で確定する結果を収集する。
func collectServerSide(label, host, loc string) (ServerSideResult, error) {
	db, err := sql.Open("mysql", dsn(host, loc))
	if err != nil {
		return ServerSideResult{}, err
	}
	defer db.Close()

	var matched, groups int
	if err := db.QueryRow(sqlWhere).Scan(&matched); err != nil {
		return ServerSideResult{}, err
	}
	if err := db.QueryRow(sqlGroups).Scan(&groups); err != nil {
		return ServerSideResult{}, err
	}
	return ServerSideResult{
		Label: label, Setting: "loc=" + loc,
		WhereMatched: matched, DateGroups: groups,
	}, nil
}

func main() {
	sourceHost := env("SOURCE_HOST", "source")
	replicaHost := env("REPLICA_HOST", "replica")

	c := Collection{
		SchemaVersion:     1,
		Language:          "Go",
		Driver:            "go-sql-driver/mysql",
		TimezoneLayer:     "DSN の `loc`（既定 `UTC`）。クライアント側パースのみ",
		IssuesSetTimeZone: false,
		SettingLabel:      "loc",
		CollectedAt:       time.Now().UTC().Format(time.RFC3339),
	}

	// loc を接続先のセッション time_zone に合わせた場合。
	for _, x := range []struct{ label, host, loc string }{
		{"source", sourceHost, "UTC"},
		{"replica", replicaHost, "Asia%2FTokyo"},
	} {
		rows, err := collectRead(x.label, x.host, x.loc)
		must(err)
		c.ReadResults = append(c.ReadResults, rows...)
	}

	// 対比: レプリカに loc=UTC（既定のまま・不一致）で接続した場合。
	c.Contrast.Title = "レプリカに `loc=UTC`（既定のまま・不一致）で接続した場合"
	rows, err := collectRead("replica", replicaHost, "UTC")
	must(err)
	c.Contrast.Results = rows

	// 同じ接続先で loc を変えても、サーバー側で確定する結果は変わらないはず。
	for _, x := range []struct{ label, host, loc string }{
		{"source", sourceHost, "UTC"},
		{"source", sourceHost, "Asia%2FTokyo"},
		{"replica", replicaHost, "UTC"},
		{"replica", replicaHost, "Asia%2FTokyo"},
	} {
		s, err := collectServerSide(x.label, x.host, x.loc)
		must(err)
		c.ServerSide = append(c.ServerSide, s)
	}

	dir := env("REPORT_DIR", "/probe/reports")
	must(os.MkdirAll(dir, 0o755))
	path := filepath.Join(dir, "go.json")
	data, err := json.MarshalIndent(c, "", "  ")
	must(err)
	must(os.WriteFile(path, append(data, '\n'), 0o644))

	fmt.Printf("収集完了: %s（%d 行 / 対比 %d 行 / サーバー側 %d 件）\n",
		path, len(c.ReadResults), len(c.Contrast.Results), len(c.ServerSide))
	fmt.Println("レポート生成: docker compose run --rm probe-report")
}

func must(err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
