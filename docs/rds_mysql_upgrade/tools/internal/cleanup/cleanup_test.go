package cleanup

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rds-mysql-upgrade/tools/internal/mysqlcli"
)

const config = `
environment: staging
aws_region: ap-northeast-1
services:
  svc:
    source_db_instance_identifier: blue
    source_engine_version: "8.0"
    source_db_parameter_group_name: pg80
    target_engine_version: 8.4.10
    target_db_parameter_group_name: pg84
    actions:
      cleanup: %s
`

// world は偽の aws が返す状態である。空文字の項目は「存在しない」。
type world struct {
	sourceVersion, sourceGroup string // 空なら移行元が無い
	deploymentStatus           string
	oldBlueStatus              string
	protected                  bool
	snapshotExists             bool
	oldBlueError               string // 旧 Blue の describe を NotFound 以外で失敗させる
}

func setup(t *testing.T, approval string, w world) (Options, string) {
	t.Helper()
	dir := t.TempDir()
	write := func(name, content string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("config.yml", strings.Replace(config, "%s", approval, 1))
	state := filepath.Join(dir, "state")
	_ = os.Mkdir(state, 0o755)
	if w.sourceVersion != "" {
		write("state/source.json", `{"DBInstances":[{"DBInstanceArn":"arn:src","EngineVersion":"`+w.sourceVersion+`","DBParameterGroups":[{"DBParameterGroupName":"`+w.sourceGroup+`"}]}]}`)
	}
	if w.deploymentStatus != "" {
		write("state/deployments.json", `{"BlueGreenDeployments":[{"BlueGreenDeploymentIdentifier":"bgd-1","Status":"`+w.deploymentStatus+`"}]}`)
	} else {
		write("state/deployments.json", `{"BlueGreenDeployments":[]}`)
	}
	if w.oldBlueStatus != "" {
		protected := "false"
		if w.protected {
			protected = "true"
		}
		write("state/old-blue.json", `{"DBInstances":[{"DBInstanceStatus":"`+w.oldBlueStatus+`","DeletionProtection":`+protected+`,"Endpoint":{"Address":"old.example"}}]}`)
	}
	if w.snapshotExists {
		write("state/snapshot", "")
	}
	if w.oldBlueError != "" {
		write("state/old-blue-error", w.oldBlueError)
	}
	log := filepath.Join(dir, "calls.log")
	script := `#!/bin/sh
d='` + state + `'
printf '%s\n' "$*" >> '` + log + `'
notfound() { echo "An error occurred ($1NotFound)" >&2; exit 254; }
case "$*" in
  *"--db-instance-identifier blue-old1"*)
    [ -f "$d/old-blue-error" ] && { cat "$d/old-blue-error" >&2; exit 254; }
    [ -f "$d/old-blue.json" ] && cat "$d/old-blue.json" || notfound DBInstance ;;
  *describe-db-instances*) [ -f "$d/source.json" ] && cat "$d/source.json" || notfound DBInstance ;;
  *describe-blue-green-deployments*) cat "$d/deployments.json" ;;
  *describe-db-snapshots*) [ -f "$d/snapshot" ] && echo '{"DBSnapshots":[{}]}' || notfound DBSnapshot ;;
  *delete-*) echo '{}' ;;
  *) echo "unexpected $*" >&2; exit 9 ;;
esac
`
	bin := filepath.Join(dir, "bin")
	_ = os.Mkdir(bin, 0o755)
	if err := os.WriteFile(filepath.Join(bin, "aws"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	out := filepath.Join(dir, "out")
	_ = os.Mkdir(out, 0o755)
	return Options{ConfigPath: filepath.Join(dir, "config.yml"), Service: "svc", OutputDir: out}, log
}

func run(t *testing.T, options Options, log string) (int, string, []string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := Run(options, &stdout, &stderr)
	calls, _ := os.ReadFile(log)
	var changes []string
	for _, line := range strings.Split(string(calls), "\n") {
		if strings.Contains(line, " delete-") {
			changes = append(changes, strings.Fields(line)[3])
		}
	}
	return code, stdout.String() + stderr.String(), changes
}

func TestScenarios(t *testing.T) {
	post := world{sourceVersion: "8.4.11", sourceGroup: "pg84"}
	pre := world{sourceVersion: "8.0.44", sourceGroup: "pg80"}
	with := func(base world, change func(*world)) world { change(&base); return base }
	for _, tc := range []struct {
		name     string
		approval string
		w        world
		code     int
		changes  string // 呼んだ変更操作（順に）
		message  string
	}{
		{"承認なしなら何もしない", "pending", post, 0, "", "cleanup: pending; no changes made."},
		{"両方無ければ完了", "approved", post, 0, "", "Cleanup already completed"},
		{"切替済みなら旧 Blue → Deployment の順に削除", "approved",
			with(post, func(w *world) { w.deploymentStatus, w.oldBlueStatus = "SWITCHOVER_COMPLETED", "available" }), 0,
			"delete-db-instance delete-blue-green-deployment", "Deployment deleted: bgd-1"},
		{"削除処理中なら待つだけ", "approved",
			with(post, func(w *world) { w.deploymentStatus, w.oldBlueStatus = "DELETING", "deleting" }), 0, "", "削除処理中"},
		{"切替前なら止める", "approved",
			with(pre, func(w *world) { w.deploymentStatus, w.oldBlueStatus = "AVAILABLE", "available" }), 1, "", "SWITCHOVER_COMPLETED"},
		{"Deployment が無くても移行後の姿なら旧 Blue を消す", "approved",
			with(post, func(w *world) { w.oldBlueStatus = "available" }), 0, "delete-db-instance", "Old Blue deletion started"},
		{"Deployment が無く移行前の姿なら止める", "approved",
			with(pre, func(w *world) { w.oldBlueStatus = "available" }), 1, "", "切替が完了していない可能性"},
		{"削除保護があれば止める", "approved",
			with(post, func(w *world) {
				w.deploymentStatus, w.oldBlueStatus, w.protected = "SWITCHOVER_COMPLETED", "available", true
			}), 1, "", "Deletion protection"},
		{"最終スナップショットが既にあれば止める", "approved",
			with(post, func(w *world) {
				w.deploymentStatus, w.oldBlueStatus, w.snapshotExists = "SWITCHOVER_COMPLETED", "available", true
			}), 1, "", "最終スナップショットが既に存在する"},
		{"旧 Blue が削除できない状態なら止める", "approved",
			with(post, func(w *world) { w.deploymentStatus, w.oldBlueStatus = "SWITCHOVER_COMPLETED", "stopped" }), 1, "", "削除できる状態にない"},
		{"移行元が無ければ止める", "approved", world{}, 1, "", "Source DB instance not found: blue"},
		{"旧 Blue の確認が権限不足なら「無い」と扱わず止める", "approved",
			with(post, func(w *world) {
				w.deploymentStatus, w.oldBlueError = "SWITCHOVER_COMPLETED", "An error occurred (AccessDenied)"
			}), 1, "", "AccessDenied"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			options, log := setup(t, tc.approval, tc.w)
			code, output, changes := run(t, options, log)
			if code != tc.code || strings.Join(changes, " ") != tc.changes || !strings.Contains(output, tc.message) {
				t.Errorf("exit=%d 変更=%v\n%s", code, changes, output)
			}
		})
	}
}

// 逆方向レプリケーションの確認（mysql は偽の Runner に差し替える）。
func TestReverseReplication(t *testing.T) {
	w := world{sourceVersion: "8.4.11", sourceGroup: "pg84", deploymentStatus: "SWITCHOVER_COMPLETED", oldBlueStatus: "available"}
	for _, tc := range []struct {
		name, io, sql string
		code          int
		deleted       bool
	}{
		{"レプリケーションが無ければ削除へ進む", "NONE", "NONE", 0, true},
		{"停止済み（OFF）なら削除へ進む", "OFF", "OFF", 0, true},
		{"接続中なら止める", "CONNECTING", "OFF", 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			options, log := setup(t, "approved", w)
			var seen []string
			options.MySQL = mysqlcli.Target{User: "checker", Port: 3306, SSLMode: "VERIFY_CA", SSLCA: "/ca.pem"}
			options.MySQLPassword = "s3cret"
			options.Runner = func(_ context.Context, _ string, args, env []string, _ string) (mysqlcli.Result, error) {
				seen = append(append(seen, args...), env...)
				xml := `<?xml version="1.0"?><resultset xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><row>` +
					`<field name="io_state">` + tc.io + `</field><field name="sql_state">` + tc.sql + `</field></row></resultset>`
				return mysqlcli.Result{Stdout: []byte(xml)}, nil
			}
			code, output, changes := run(t, options, log)
			if code != tc.code || (len(changes) > 0) != tc.deleted {
				t.Fatalf("exit=%d 変更=%v\n%s", code, changes, output)
			}
			joined := strings.Join(seen, " ")
			if !strings.Contains(joined, "--host=old.example") || !strings.Contains(joined, "--ssl-mode=VERIFY_CA") ||
				!strings.Contains(joined, "MYSQL_PWD=s3cret") || strings.Contains(joined, "--password=") {
				t.Errorf("接続の渡し方が違う: %s", joined)
			}
		})
	}
	// 検証するモードで CA が無ければ、接続する前に止める。
	options, log := setup(t, "approved", w)
	options.MySQL = mysqlcli.Target{User: "checker", Port: 3306}
	options.MySQLPassword = "x"
	if code, output, changes := run(t, options, log); code != 1 || len(changes) != 0 || !strings.Contains(output, "--ssl-ca") {
		t.Errorf("CA 無しの VERIFY_CA を止めること: exit=%d\n%s", code, output)
	}
}
