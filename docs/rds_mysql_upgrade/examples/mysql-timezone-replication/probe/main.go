// タイムゾーン差異のドライバ検証（Go / go-sql-driver/mysql）。
//
// 検証する内容:
//   フェーズ 1: 読み取り値の解釈。DSN の loc を接続先のセッション time_zone に
//               合わせれば、ドライバが解釈した絶対時刻はサーバーの
//               UNIX_TIMESTAMP(ts) と一致する（差を吸収できる）。
//   フェーズ 2: サーバー側で確定する結果。loc を変えても WHERE の該当件数と
//               GROUP BY DATE() のグループ数は変わらない（吸収できない）。
package main

import (
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func dsn(host, loc string) string {
	return fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&loc=%s",
		env("MYSQL_USER", "root"),
		os.Getenv("MYSQL_PWD"),
		host,
		env("MYSQL_PORT", "3306"),
		env("MYSQL_DATABASE", "tzcheck"),
		loc,
	)
}

// フェーズ 1: 読み取り値をドライバがどう解釈するか。
func probeRead(label, host, loc string) error {
	db, err := sql.Open("mysql", dsn(host, loc))
	if err != nil {
		return err
	}
	defer db.Close()

	var sessionTZ string
	if err := db.QueryRow("SELECT @@session.time_zone").Scan(&sessionTZ); err != nil {
		return err
	}
	fmt.Printf("[%s] loc=%s session_time_zone=%s\n", label, loc, sessionTZ)

	rows, err := db.Query("SELECT id, ts, UNIX_TIMESTAMP(ts) FROM t ORDER BY id")
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		var ts time.Time
		var serverEpoch int64
		if err := rows.Scan(&id, &ts, &serverEpoch); err != nil {
			return err
		}
		fmt.Printf("  id=%d driver=%s driver_unix=%d server_unix=%d match=%v\n",
			id, ts.Format("2006-01-02 15:04:05 -0700"),
			ts.Unix(), serverEpoch, ts.Unix() == serverEpoch)
	}
	return rows.Err()
}

// フェーズ 2: サーバー側で確定する結果。loc の影響を受けないことを確認する。
func probeServerSide(label, host, loc string) error {
	db, err := sql.Open("mysql", dsn(host, loc))
	if err != nil {
		return err
	}
	defer db.Close()

	var matched, groups int
	if err := db.QueryRow(
		"SELECT COUNT(*) FROM t WHERE ts >= '2026-09-03 00:00:00'").Scan(&matched); err != nil {
		return err
	}
	if err := db.QueryRow(
		"SELECT COUNT(*) FROM (SELECT DATE(ts) FROM t GROUP BY DATE(ts)) g").Scan(&groups); err != nil {
		return err
	}
	fmt.Printf("[%s] loc=%-12s where_matched=%d date_groups=%d\n", label, loc, matched, groups)
	return nil
}

func main() {
	sourceHost := env("SOURCE_HOST", "source")
	replicaHost := env("REPLICA_HOST", "replica")

	fmt.Println("=== フェーズ 1: 読み取り値の解釈（loc を接続先に合わせる → 吸収できる） ===")
	checks := []struct{ label, host, loc string }{
		{"source", sourceHost, "UTC"},
		{"replica", replicaHost, "Asia%2FTokyo"},
	}
	for _, c := range checks {
		if err := probeRead(c.label, c.host, c.loc); err != nil {
			fmt.Fprintf(os.Stderr, "error (%s): %v\n", c.label, err)
			os.Exit(1)
		}
	}

	fmt.Println()
	fmt.Println("=== 参考: レプリカに loc=UTC（既定のまま）で接続すると match=false になる ===")
	if err := probeRead("replica", replicaHost, "UTC"); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println()
	fmt.Println("=== フェーズ 2: サーバー側で確定する結果（loc を変えても変わらない） ===")
	serverSide := []struct{ label, host, loc string }{
		{"source", sourceHost, "UTC"},
		{"source", sourceHost, "Asia%2FTokyo"},
		{"replica", replicaHost, "UTC"},
		{"replica", replicaHost, "Asia%2FTokyo"},
	}
	for _, c := range serverSide {
		if err := probeServerSide(c.label, c.host, c.loc); err != nil {
			fmt.Fprintf(os.Stderr, "error (%s): %v\n", c.label, err)
			os.Exit(1)
		}
	}
}
