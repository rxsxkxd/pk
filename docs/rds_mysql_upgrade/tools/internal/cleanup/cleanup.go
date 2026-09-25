// Package cleanup は Step 7（後始末）を担う。Blue/Green Deployment と旧 Blue
// （<source>-old1）を削除する。**不可逆な変更操作であり、パイプラインからは外して人が実行する。**
//
// 冪等性の担保:
//
//	望ましい終了状態を「Deployment が存在せず、かつ旧 Blue が存在しない」と定義し、
//	2 つのリソースを独立に判定する。片方の完了を全体の完了とみなさない
//	（Deployment だけ消えて旧 Blue が残り、課金が続く状態を見逃さないため）。
//
// 削除の前に次を確かめる。
//
//  1. 設定ファイルの actions.cleanup が approved であること
//  2. 切替が完了していること（Deployment が残っていれば SWITCHOVER_COMPLETED、
//     消えていれば移行元が「移行後」の姿であること。判定は internal/phase）
//  3. 旧 Blue の削除保護が無効であること
//  4. [--mysql-user 指定時のみ] 旧 Blue に逆方向レプリケーションが張られていないこと
//     （AWS の読み取り API には現れないため、DB へ接続してしか判定できない）
//
// 終了コード: 0 望ましい終了状態に到達（削除処理中を含む） / 1 到達しておらず自動では到達できない
package cleanup

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"rds-mysql-upgrade/tools/internal/awscli"
	"rds-mysql-upgrade/tools/internal/deployconfig"
	"rds-mysql-upgrade/tools/internal/mysqlcli"
	"rds-mysql-upgrade/tools/internal/phase"
)

// Options は後始末の入力である。
type Options struct {
	ConfigPath string
	Service    string
	Region     string // 空なら設定ファイルの aws_region
	Profile    string
	OutputDir  string

	// 逆方向レプリケーションの確認（任意）。MySQL.User が空なら確認しない。
	MySQL         mysqlcli.Target // Host は旧 Blue のエンドポイントで上書きする
	MySQLPassword string          // 空なら対話入力（端末が無ければ失敗）
	MySQLBin      string
	Runner        mysqlcli.Runner
	ReadPassword  func(prompt string) (string, error)
}

// 逆方向レプリケーションの状態。performance_schema の SERVICE_STATE を見る
// （SHOW REPLICA STATUS の文言はバージョンで揺れるため）。**読み取りだけである。**
const replicationStateSQL = "SELECT " +
	"IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_connection_status LIMIT 1),'NONE') AS io_state, " +
	"IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_applier_status LIMIT 1),'NONE') AS sql_state"

type instanceDescription struct {
	DBInstances []struct {
		DBInstanceArn      string `json:"DBInstanceArn"`
		DBInstanceStatus   string `json:"DBInstanceStatus"`
		EngineVersion      string `json:"EngineVersion"`
		DeletionProtection bool   `json:"DeletionProtection"`
		DBParameterGroups  []struct {
			DBParameterGroupName string `json:"DBParameterGroupName"`
		} `json:"DBParameterGroups"`
		Endpoint struct {
			Address string `json:"Address"`
		} `json:"Endpoint"`
	} `json:"DBInstances"`
}

// Run は後始末を行い、終了コードを返す。
func Run(options Options, stdout, stderr io.Writer) int {
	say := func(format string, args ...any) { fmt.Fprintf(stdout, format+"\n", args...) }
	fail := func(format string, args ...any) int {
		fmt.Fprintf(stderr, format+"\n", args...)
		return 1
	}

	config, err := deployconfig.Load(options.ConfigPath)
	if err != nil {
		return fail("%v", err)
	}
	service, err := config.Service(options.Service)
	if err != nil {
		return fail("%v", err)
	}
	values := map[string]string{}
	for _, key := range []string{"source_db_instance_identifier", "source_engine_version", "source_db_parameter_group_name",
		"target_engine_version", "target_db_parameter_group_name"} {
		if values[key], err = service.Required(key); err != nil {
			return fail("%v", err)
		}
	}
	configRegion, err := config.Required("aws_region")
	if err != nil {
		return fail("%v", err)
	}
	sourceID := values["source_db_instance_identifier"]
	// 未指定なら移行元識別子から決める。固定名にすることで、途中失敗後の再実行で
	// スナップショットが増殖しない。
	finalSnapshotID := service.Optional("final_snapshot_identifier", sourceID+"-final")
	if service.Optional("actions.cleanup", "pending") != "approved" {
		say("cleanup: pending; no changes made.")
		return 0
	}
	region := options.Region
	if region == "" {
		region = configRegion
	}
	aws := awscli.Client{Region: region, Profile: options.Profile}
	save := func(name string) string { return filepath.Join(options.OutputDir, name) }
	oldBlueID := sourceID + "-old1"

	// --- 2 つのリソースの現在地を独立に把握する -------------------------------
	// [読み取り] 移行元識別子が指す実体。切替後は green（新 Blue）を指す。
	var source instanceDescription
	if err := aws.JSON(save("source.json"), &source, "rds", "describe-db-instances", "--db-instance-identifier", sourceID); err != nil {
		if awscli.NotFound(err) {
			return fail("Source DB instance not found: %s", sourceID)
		}
		return fail("%v", err)
	}
	if len(source.DBInstances) == 0 {
		return fail("Source DB instance not found: %s", sourceID)
	}
	currentVersion := source.DBInstances[0].EngineVersion
	currentGroup := ""
	if groups := source.DBInstances[0].DBParameterGroups; len(groups) > 0 {
		currentGroup = groups[0].DBParameterGroupName
	}
	resolved := phase.Resolve(currentVersion, currentGroup,
		values["source_engine_version"], values["source_db_parameter_group_name"],
		values["target_engine_version"], values["target_db_parameter_group_name"])

	// [読み取り] Deployment。設定値ではなく AWS の実状態から対象を解決する。
	var deployments struct {
		BlueGreenDeployments []struct {
			BlueGreenDeploymentIdentifier string `json:"BlueGreenDeploymentIdentifier"`
			Status                        string `json:"Status"`
		} `json:"BlueGreenDeployments"`
	}
	if err := aws.JSON(save("deployment.json"), &deployments, "rds", "describe-blue-green-deployments",
		"--filters", "Name=source,Values="+source.DBInstances[0].DBInstanceArn); err != nil {
		return fail("%v", err)
	}
	deploymentID, deploymentStatus := "", ""
	if len(deployments.BlueGreenDeployments) > 0 {
		deploymentID = deployments.BlueGreenDeployments[0].BlueGreenDeploymentIdentifier
		deploymentStatus = deployments.BlueGreenDeployments[0].Status
	}

	// [読み取り] 旧 Blue。RDS はスイッチオーバー時に <source>-old1 へ自動リネームする。
	// 「存在しない」と扱うのは DBInstanceNotFound のときだけで、権限不足などは止める。
	var oldBlue instanceDescription
	oldBlueStatus := ""
	if err := aws.JSON(save("old-blue.json"), &oldBlue, "rds", "describe-db-instances", "--db-instance-identifier", oldBlueID); err != nil {
		if !awscli.NotFound(err) {
			return fail("%v", err)
		}
	} else if len(oldBlue.DBInstances) > 0 {
		oldBlueStatus = oldBlue.DBInstances[0].DBInstanceStatus
	}

	shownDeployment := "（無し）"
	if deploymentID != "" {
		shownDeployment = deploymentID
		if deploymentStatus != "" {
			shownDeployment += " / " + deploymentStatus
		}
	}
	shownOldBlue := oldBlueStatus
	if shownOldBlue == "" {
		shownOldBlue = "（無し）"
	}
	say("現在地:")
	say("  移行フェーズ: %s (%s / %s)", resolved, currentVersion, currentGroup)
	say("  Deployment:   %s", shownDeployment)
	say("  旧 Blue:      %s %s", oldBlueID, shownOldBlue)

	// --- 望ましい終了状態に到達済みか -----------------------------------------
	if deploymentID == "" && oldBlueStatus == "" {
		say("Cleanup already completed: Deployment も 旧 Blue も存在しない。")
		say("Artifacts: %s", options.OutputDir)
		return 0
	}

	// --- 安全弁: 切替が完了していることを確認する -----------------------------
	// Deployment が残っていれば Status で、消えていれば移行元の姿で確認する。
	// これにより「Deployment 削除に成功し旧 Blue の削除に失敗した」状態からでも再開できる。
	if deploymentID != "" {
		switch deploymentStatus {
		case "SWITCHOVER_COMPLETED":
		case "DELETING":
			say("Deployment は削除処理中である: %s", deploymentID)
		default:
			return fail("Cleanup requires SWITCHOVER_COMPLETED status; current status: %s", deploymentStatus)
		}
	} else if resolved != phase.Post {
		fmt.Fprintln(stderr, "Deployment が存在せず、かつ移行元が「移行後」の姿ではない。切替が完了していない可能性がある。")
		return fail("%s", phase.Describe(currentVersion, currentGroup,
			values["source_engine_version"], values["source_db_parameter_group_name"],
			values["target_engine_version"], values["target_db_parameter_group_name"]))
	}

	// --- 旧 Blue の削除 --------------------------------------------------------
	switch oldBlueStatus {
	case "":
		say("旧 Blue は既に存在しない: %s", oldBlueID)
	case "deleting":
		say("旧 Blue は削除処理中である: %s", oldBlueID)
	case "available":
		if oldBlue.DBInstances[0].DeletionProtection {
			return fail("Deletion protection is enabled on %s. Disable it before cleanup.", oldBlueID)
		}
		if code := checkReverseReplication(options, oldBlueID, oldBlue.DBInstances[0].Endpoint.Address, stdout, stderr); code != 0 {
			return code
		}
		// 最終スナップショットが既に存在する場合は、以前の削除が進行済みであることを意味する。
		if err := aws.JSON("", nil, "rds", "describe-db-snapshots", "--db-snapshot-identifier", finalSnapshotID); err == nil {
			fmt.Fprintf(stderr, "最終スナップショットが既に存在する: %s\n", finalSnapshotID)
			return fail("以前の削除が途中まで進んでいる可能性がある。内容を確認してから再実行する。")
		} else if !awscli.NotFound(err) {
			return fail("%v", err)
		}
		// [変更] 旧 Blue を最終スナップショット付きで削除する。不可逆な操作。
		if err := aws.JSON(save("delete-db-instance.json"), nil, "rds", "delete-db-instance",
			"--db-instance-identifier", oldBlueID, "--final-db-snapshot-identifier", finalSnapshotID); err != nil {
			return fail("%v", err)
		}
		say("Old Blue deletion started: %s (final snapshot: %s)", oldBlueID, finalSnapshotID)
	default:
		return fail("旧 Blue が削除できる状態にない: %s (status: %s)", oldBlueID, oldBlueStatus)
	}

	// --- Deployment の削除 -----------------------------------------------------
	// 旧 Blue の削除を先に行う。逆順にすると、Deployment だけ消えて旧 Blue が残った場合に
	// 「切替が完了したか」を確認する手がかりが減るためである（phase 判定で代替はできる）。
	if deploymentID != "" && deploymentStatus != "DELETING" {
		// [変更] Blue/Green Deployment を削除する。Green（切替後の本番）はそのまま残る。
		if err := aws.JSON(save("delete-blue-green-deployment.json"), nil, "rds", "delete-blue-green-deployment",
			"--blue-green-deployment-identifier", deploymentID); err != nil {
			return fail("%v", err)
		}
		say("Deployment deleted: %s", deploymentID)
	}
	say("Artifacts: %s", options.OutputDir)
	return 0
}

// checkReverseReplication は旧 Blue に逆方向レプリケーションが残っていないかを確かめる。
// --mysql-user が無ければ確かめず、警告だけ出す（本番 DB の認証情報を CI に置かない方針のため任意）。
func checkReverseReplication(options Options, oldBlueID, endpoint string, stdout, stderr io.Writer) int {
	if options.MySQL.User == "" {
		fmt.Fprintln(stderr, "WARNING: --mysql-user not given; reverse replication was not checked. "+
			"Confirm manually from a local run before approving cleanup.")
		return 0
	}
	target := options.MySQL
	target.Host = endpoint
	if err := target.Validate(); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if warning := target.SecurityWarning(); warning != "" {
		fmt.Fprintln(stderr, warning)
	}
	password := options.MySQLPassword
	if password == "" {
		if options.ReadPassword == nil {
			fmt.Fprintln(stderr, "MySQL のパスワードが無く、対話入力もできない。--mysql-password-env の環境変数で渡すこと。")
			return 1
		}
		var err error
		if password, err = options.ReadPassword(fmt.Sprintf("MySQL password for %s@%s: ", target.User, endpoint)); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
	}
	runner := options.Runner
	if runner == nil {
		runner = mysqlcli.ExecRunner
	}
	bin := options.MySQLBin
	if bin == "" {
		bin = "mysql"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	rows, err := mysqlcli.Query(ctx, runner, bin, target, password, replicationStateSQL)
	if err != nil {
		fmt.Fprintf(stderr, "逆方向レプリケーションを確認できなかった（%v）\n", err)
		return 1
	}
	ioState, sqlState := "NONE", "NONE"
	if len(rows) > 0 {
		if value := rows[0]["io_state"]; value != nil {
			ioState = *value
		}
		if value := rows[0]["sql_state"]; value != nil {
			sqlState = *value
		}
	}
	fmt.Fprintf(stdout, "Reverse replication state on %s: IO=%s SQL=%s\n", oldBlueID, ioState, sqlState)
	if (ioState != "NONE" && ioState != "OFF") || (sqlState != "NONE" && sqlState != "OFF") {
		fmt.Fprintf(stderr, "Reverse replication is still active on %s. Aborting cleanup.\n", oldBlueID)
		return 1
	}
	return 0
}

// ReadPasswordFromTerminal は端末からエコーせずにパスワードを読む（stty を使う）。
// 端末が無ければエラーを返す（CI で入力待ちのまま止まらないように）。
func ReadPasswordFromTerminal(prompt string) (string, error) {
	info, err := os.Stdin.Stat()
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return "", fmt.Errorf("MySQL のパスワードが無く、端末も無いので対話入力できない。--mysql-password-env の環境変数で渡すこと")
	}
	fmt.Fprint(os.Stderr, prompt)
	if err := stty("-echo"); err != nil {
		return "", err
	}
	defer func() {
		_ = stty("echo")
		fmt.Fprintln(os.Stderr)
	}()
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && line == "" {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

// stty は端末のエコーを切り替える。
func stty(setting string) error {
	command := exec.Command("stty", setting)
	command.Stdin = os.Stdin
	return command.Run()
}
