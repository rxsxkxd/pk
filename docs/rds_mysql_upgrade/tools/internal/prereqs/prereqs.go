// Package prereqs は Step 1（成立条件チェック）の AWS 側を担う。
//
//   - Collect  … AWS の読み取り API（Describe* / Get*）だけで JSON を集める。**判定はしない**
//   - Evaluate … 集めた JSON だけを読んで判定する。**AWS を呼ばない**
//
// 判定は PASS / REVIEW / STOP の 3 段階で、項目の採番は docs/phase-0-precheck.md に対応する。
// Markdown レポートはゲート①（移行できるか／どれを対象にするか）の判断材料であり、
// 判定だけでなく**観測値と取得元**を残す。
package prereqs

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"rds-mysql-upgrade/tools/internal/awscli"
	"rds-mysql-upgrade/tools/internal/mysqlcli"
)

// ---------------------------------------------------------------------------
// 収集
// ---------------------------------------------------------------------------

// CollectOptions は収集の入力である。
type CollectOptions struct {
	Client              awscli.Client
	DBInstanceID        string
	TargetEngineVersion string
	OutputDir           string
	Now                 func() time.Time // テストで時刻を固定するため
}

// Metadata は metadata.json の内容である。
type Metadata struct {
	DBInstanceID        string `json:"db_instance_id"`
	TargetEngineVersion string `json:"target_engine_version"`
	CollectedAt         string `json:"collected_at"`
}

// Collect は判定に要る JSON を OutputDir へ書き出す。以下はすべて読み取り API である。
func Collect(options CollectOptions) error {
	if options.Now == nil {
		options.Now = time.Now
	}
	client := options.Client
	save := func(name string) string { return filepath.Join(options.OutputDir, name) }

	// [0-1-01][0-1-05][0-1-07][0-1-08][0-1-10][0-1-12][0-1-14]
	// 対象 Blue のバックアップ保持期間、DB クラス、適用中のパラメータ／オプション
	// グループ、上流／配下リードレプリカ、Secrets Manager・IAM DB 認証の利用状態。
	// パラメータグループ名とオプショングループ名もこの応答から取る（同じ API を二度叩かない）。
	var instance struct {
		DBInstances []struct {
			DBParameterGroups []struct {
				DBParameterGroupName string `json:"DBParameterGroupName"`
			} `json:"DBParameterGroups"`
			OptionGroupMemberships []struct {
				OptionGroupName string `json:"OptionGroupName"`
			} `json:"OptionGroupMemberships"`
		} `json:"DBInstances"`
	}
	if err := client.JSON(save("db-instance.json"), &instance,
		"rds", "describe-db-instances", "--db-instance-identifier", options.DBInstanceID); err != nil {
		return err
	}
	if len(instance.DBInstances) == 0 {
		return fmt.Errorf("DB インスタンス %s が見つからない", options.DBInstanceID)
	}
	parameterGroup, optionGroup := "", ""
	if groups := instance.DBInstances[0].DBParameterGroups; len(groups) > 0 {
		parameterGroup = groups[0].DBParameterGroupName
	}
	if groups := instance.DBInstances[0].OptionGroupMemberships; len(groups) > 0 {
		optionGroup = groups[0].OptionGroupName
	}

	// [0-1-06] 外部 binlog レプリカは AWS API では判定できない。MySQL 側の収集
	// （collect_blue_mysql_state）が SHOW REPLICA STATUS を取る。

	// [0-1-07] 同一リージョンの全 DB インスタンス。カスケード構成の判定に使う。
	if err := client.JSON(save("all-db-instances.json"), nil, "rds", "describe-db-instances"); err != nil {
		return err
	}
	// [0-1-02] 適用中のパラメータグループの全パラメータ（binlog_format の現行値を記録する）。
	if err := client.JSON(save("db-parameters.json"), nil,
		"rds", "describe-db-parameters", "--db-parameter-group-name", parameterGroup); err != nil {
		return err
	}
	// [0-1-03][0-1-04] 適用中オプショングループの全オプション（既定グループか、MEMCACHED の有無）。
	if err := client.JSON(save("option-group.json"), nil,
		"rds", "describe-option-groups", "--option-group-name", optionGroup); err != nil {
		return err
	}
	// [0-1-08] 移行先バージョンで作成可能な DB クラス。
	if err := client.JSON(save("orderable-classes.json"), nil,
		"rds", "describe-orderable-db-instance-options", "--engine", "mysql",
		"--engine-version", options.TargetEngineVersion); err != nil {
		return err
	}
	// [0-1-13] リージョン内の RDS Proxy と、各 Proxy の登録ターゲット。
	var proxies struct {
		DBProxies []struct {
			DBProxyName string `json:"DBProxyName"`
		} `json:"DBProxies"`
	}
	if err := client.JSON(save("db-proxies.json"), &proxies, "rds", "describe-db-proxies"); err != nil {
		return err
	}
	for index, proxy := range proxies.DBProxies {
		if proxy.DBProxyName == "" {
			continue
		}
		if err := client.JSON(save(fmt.Sprintf("db-proxy-targets-%d.json", index)), nil,
			"rds", "describe-db-proxy-targets", "--db-proxy-name", proxy.DBProxyName); err != nil {
			return err
		}
	}
	// [0-1-11] リージョン内の RDS Integration（Zero-ETL 統合を含む）。
	if err := client.JSON(save("integrations.json"), nil, "rds", "describe-integrations"); err != nil {
		return err
	}
	// [0-1-09] FreeStorageSpace の直近 1 時間の最小値（Byte）。
	end := options.Now().UTC()
	start := end.Add(-time.Hour)
	if err := client.JSON(save("free-storage-space.json"), nil,
		"cloudwatch", "get-metric-statistics", "--namespace", "AWS/RDS", "--metric-name", "FreeStorageSpace",
		"--dimensions", "Name=DBInstanceIdentifier,Value="+options.DBInstanceID,
		"--statistics", "Minimum", "--period", "300",
		"--start-time", start.Format(time.RFC3339), "--end-time", end.Format(time.RFC3339)); err != nil {
		return err
	}

	metadata, err := json.Marshal(Metadata{
		DBInstanceID: options.DBInstanceID, TargetEngineVersion: options.TargetEngineVersion,
		CollectedAt: end.Format(time.RFC3339),
	})
	if err != nil {
		return err
	}
	return os.WriteFile(save("metadata.json"), append(metadata, '\n'), 0o644)
}

// ---------------------------------------------------------------------------
// 判定
// ---------------------------------------------------------------------------

// Result は 1 項目の判定である。
type Result struct {
	Status string // PASS / REVIEW / STOP
	Item   string // チェック項目（docs/phase-0-precheck.md の採番に対応）
	Detail string // 判定の根拠になった観測値
	Source string // その値をどの収集ファイルから読んだか（証跡として残す）
}

// Evaluation は判定の結果一式である。
type Evaluation struct {
	InstanceID    string
	Engine        string
	EngineVersion string
	InstanceClass string
	Metadata      map[string]any
	Results       []Result
	MySQL         mysqlSide // MySQL 側の収集結果（任意。無ければ該当項目は REVIEW）

	Endpoint       string // 対象 Blue のエンドポイント（MySQL 側の接続先の確認に使う）
	binlogDeclared string // パラメータグループ上の binlog_format
}

// Count は指定した判定の件数を返す。
func (e *Evaluation) Count(status string) int {
	count := 0
	for _, result := range e.Results {
		if result.Status == status {
			count++
		}
	}
	return count
}

// MissingError は収集ファイルが無いことを示す。
type MissingError struct{ Name string }

func (e *MissingError) Error() string {
	return fmt.Sprintf("Missing %s; run the collector again.", e.Name)
}

func readJSON(dir, name string) (map[string]any, error) {
	content, err := os.ReadFile(filepath.Join(dir, name))
	if os.IsNotExist(err) {
		return nil, &MissingError{Name: name}
	}
	if err != nil {
		return nil, err
	}
	return decode(content, name)
}

func decode(content []byte, name string) (map[string]any, error) {
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.UseNumber() // 数値は書かれたとおりの表記で扱う（7 を 7.0 にしない）
	var document map[string]any
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("%s: JSON を解析できない: %w", name, err)
	}
	return document, nil
}

// 汎用 JSON を辿る小さな道具。欠けていれば空を返す（Ruby の fetch/[] の使い分けは呼び出し側で表す）。
func list(document map[string]any, key string) []any {
	values, _ := document[key].([]any)
	return values
}

func object(value any) map[string]any {
	mapping, _ := value.(map[string]any)
	return mapping
}

func first(values []any) map[string]any {
	if len(values) == 0 {
		return nil
	}
	return object(values[0])
}

// text は Ruby の to_s 相当（nil は空文字、数値は書かれた表記）。
func text(value any) string {
	if value == nil {
		return ""
	}
	return fmt.Sprint(value)
}

// truthy は Ruby の真偽（nil と false だけが偽）。
func truthy(value any) bool {
	if value == nil {
		return false
	}
	if boolean, ok := value.(bool); ok {
		return boolean
	}
	return true
}

func number(value any) (float64, bool) {
	switch typed := value.(type) {
	case json.Number:
		f, err := typed.Float64()
		return f, err == nil
	case float64:
		return typed, true
	}
	return 0, false
}

func pick(values []any, key string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		result = append(result, text(object(value)[key]))
	}
	return result
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

// Evaluate は収集済み JSON を判定する。AWS は呼ばない。
func Evaluate(dir string) (*Evaluation, error) {
	files := map[string]map[string]any{}
	for _, name := range []string{"metadata.json", "db-instance.json", "all-db-instances.json", "db-parameters.json",
		"option-group.json", "orderable-classes.json", "db-proxies.json", "integrations.json", "free-storage-space.json"} {
		document, err := readJSON(dir, name)
		if err != nil {
			return nil, err
		}
		files[name] = document
	}
	metadata := files["metadata.json"]
	instance := first(list(files["db-instance.json"], "DBInstances"))
	if instance == nil {
		return nil, fmt.Errorf("db-instance.json: DBInstances が空である")
	}
	instances := list(files["all-db-instances.json"], "DBInstances")
	parameters := list(files["db-parameters.json"], "Parameters")
	optionGroup := first(list(files["option-group.json"], "OptionGroupsList"))
	orderable := list(files["orderable-classes.json"], "OrderableDBInstanceOptions")
	proxies := list(files["db-proxies.json"], "DBProxies")
	integrations := list(files["integrations.json"], "Integrations")
	storage := list(files["free-storage-space.json"], "Datapoints")
	targetPaths, _ := filepath.Glob(filepath.Join(dir, "db-proxy-targets-*.json"))
	sort.Strings(targetPaths)
	var proxyTargets []any
	for _, path := range targetPaths {
		content, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		document, err := decode(content, filepath.Base(path))
		if err != nil {
			return nil, err
		}
		proxyTargets = append(proxyTargets, list(document, "Targets")...)
	}

	side, err := readMySQLSide(dir)
	if err != nil {
		return nil, err
	}

	evaluation := &Evaluation{
		InstanceID: text(instance["DBInstanceIdentifier"]), Engine: text(instance["Engine"]),
		EngineVersion: text(instance["EngineVersion"]), InstanceClass: text(instance["DBInstanceClass"]),
		Metadata: metadata, MySQL: side,
		Endpoint: text(object(instance["Endpoint"])["Address"]),
	}
	add := func(status, item, detail, source string) {
		evaluation.Results = append(evaluation.Results, Result{status, item, detail, source})
	}
	verdict := func(pass bool, otherwise string) string {
		if pass {
			return "PASS"
		}
		return otherwise
	}

	backup := "0"
	backupDays := 0.0
	if value, ok := number(instance["BackupRetentionPeriod"]); ok {
		backup, backupDays = text(instance["BackupRetentionPeriod"]), value
	}
	add(verdict(backupDays >= 1, "STOP"), "0-1-01 自動バックアップ", "BackupRetentionPeriod="+backup, "db-instance.json")

	binlogValue := ""
	for _, parameter := range parameters {
		if text(object(parameter)["ParameterName"]) == "binlog_format" {
			binlogValue = text(object(parameter)["ParameterValue"])
			break
		}
	}
	evaluation.binlogDeclared = binlogValue
	effective := side.binlogEffective()
	effectiveNote := ""
	if effective != "" {
		effectiveNote = "。実効値=" + effective
	}
	switch {
	case binlogValue == "ROW" && (effective == "" || effective == "ROW"):
		add("PASS", "0-1-02 binlog_format", "ROW（Green 作成の必須条件ではないが、運用方針と一致）"+effectiveNote, "db-parameters.json")
	case effective != "" && binlogValue != "" && effective != binlogValue:
		add("REVIEW", "0-1-02 binlog_format", "パラメータグループ="+binlogValue+effectiveNote+"（食い違っている。適用待ちや上書きを確認する）",
			"db-parameters.json / "+mysqlcli.StateFileName)
	default:
		shown := binlogValue
		if shown == "" {
			shown = "取得不可"
		}
		add("REVIEW", "0-1-02 binlog_format", shown+"（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）"+effectiveNote, "db-parameters.json")
	}

	var statuses []string
	for _, status := range pick(list(instance, "DBParameterGroups"), "ParameterApplyStatus") {
		if !contains(statuses, status) {
			statuses = append(statuses, status)
		}
	}
	add(verdict(len(statuses) == 1 && statuses[0] == "in-sync", "STOP"), "0-1-05 パラメータ適用状態",
		strings.Join(statuses, ", "), "db-instance.json")

	optionName := text(first(list(instance, "OptionGroupMemberships"))["OptionGroupName"])
	add(verdict(strings.HasPrefix(optionName, "default:"), "STOP"), "0-1-03 オプショングループ", optionName, "db-instance.json")

	optionNames := pick(list(optionGroup, "Options"), "OptionName")
	optionDetail := strings.Join(optionNames, ", ")
	if len(optionNames) == 0 {
		optionDetail = "設定なし"
	}
	add(verdict(!contains(optionNames, "MEMCACHED"), "STOP"), "0-1-04 MEMCACHED", optionDetail, "option-group.json")

	evaluation.Results = append(evaluation.Results, side.replicaResult())

	childIDs := make([]string, 0)
	for _, id := range list(instance, "ReadReplicaDBInstanceIdentifiers") {
		childIDs = append(childIDs, text(id))
	}
	cascade := false
	for _, candidate := range instances {
		child := object(candidate)
		if contains(childIDs, text(child["DBInstanceIdentifier"])) || contains(childIDs, text(child["DBInstanceArn"])) {
			cascade = cascade || len(list(child, "ReadReplicaDBInstanceIdentifiers")) > 0
		}
	}
	cascadeDetail := fmt.Sprintf("直接配下=%d", len(childIDs))
	if cascade {
		cascadeDetail = "配下レプリカにさらに配下レプリカあり"
	}
	add(verdict(!cascade, "STOP"), "0-1-07 カスケードリードレプリカ", cascadeDetail, "all-db-instances.json")

	available := contains(pick(orderable, "DBInstanceClass"), evaluation.InstanceClass)
	add(verdict(available, "STOP"), "0-1-08 インスタンスクラス",
		fmt.Sprintf("%s / target=%s", evaluation.InstanceClass, text(metadata["target_engine_version"])), "orderable-classes.json")

	var minimum *float64
	for _, point := range storage {
		value, _ := number(object(point)["Minimum"])
		if minimum == nil || value < *minimum {
			v := value
			minimum = &v
		}
	}
	storageDetail := "メトリクス取得なし"
	if minimum != nil {
		storageDetail = fmt.Sprintf("直近1時間の最小値: %.2f GiB", *minimum/(1<<30))
	}
	add(verdict(minimum != nil && *minimum >= 2*(1<<30), "REVIEW"), "0-1-09 空きストレージ", storageDetail, "free-storage-space.json")

	managedPassword := truthy(instance["ManageMasterUserPassword"]) || instance["MasterUserSecret"] != nil
	passwordDetail := "利用なし"
	if managedPassword {
		passwordDetail = "利用あり。制約と再設定手順を確認"
	}
	add(verdict(!managedPassword, "REVIEW"), "0-1-10 Secrets Manager 管理パスワード", passwordDetail, "db-instance.json")

	dbARN := text(instance["DBInstanceArn"])
	var related []string
	for _, candidate := range integrations {
		integration := object(candidate)
		if text(integration["SourceArn"]) == dbARN || text(integration["TargetArn"]) == dbARN {
			related = append(related, text(integration["IntegrationArn"]))
		}
	}
	integrationDetail := "関連統合なし"
	if len(related) > 0 {
		integrationDetail = strings.Join(related, ", ")
	}
	add(verdict(len(related) == 0, "REVIEW"), "0-1-11 Zero-ETL 統合", integrationDetail, "integrations.json")

	region := func(arn string) string {
		parts := strings.Split(arn, ":")
		if len(parts) > 3 {
			return parts[3]
		}
		return ""
	}
	crossRegion := false
	for _, id := range childIDs {
		crossRegion = crossRegion || (strings.HasPrefix(id, "arn:") && region(id) != region(dbARN))
	}
	crossDetail := "検出なし"
	if crossRegion {
		crossDetail = "関連 ARN を確認"
	}
	add(verdict(!crossRegion, "REVIEW"), "0-1-12 クロスリージョンリードレプリカ", crossDetail, "db-instance.json")

	resourceID := text(instance["DbiResourceId"])
	registered := contains(pick(proxyTargets, "RdsResourceId"), resourceID)
	proxyNames := strings.Join(pick(proxies, "DBProxyName"), ", ")
	proxyDetail := "Proxy=" + proxyNames + "。対象 Blue の登録なし"
	switch {
	case len(proxies) == 0:
		proxyDetail = "このリージョンに Proxy なし"
	case registered:
		proxyDetail = "対象 Blue は Proxy ターゲットに登録済み（" + proxyNames + "）"
	}
	add(verdict(len(proxies) == 0 || registered, "REVIEW"), "0-1-13 RDS Proxy", proxyDetail, "db-proxies.json / db-proxy-targets-*.json")

	iamAuth := truthy(instance["IAMDatabaseAuthenticationEnabled"])
	iamDetail := "無効"
	if iamAuth {
		iamDetail = "有効。Green 用リソース ID の IAM ポリシー更新手順を確認"
	}
	add(verdict(!iamAuth, "REVIEW"), "0-1-14 IAM DB 認証", iamDetail, "db-instance.json")

	// MySQL 側の収集結果による項目（無ければ REVIEW＝未収集）。
	evaluation.Results = append(evaluation.Results, side.engineResult(), side.checkerResult())
	return evaluation, nil
}

// ---------------------------------------------------------------------------
// 出力
// ---------------------------------------------------------------------------

// pad は Ruby の format('%-Ns') と同じく、文字数で右側を埋める。
func pad(value string, width int) string {
	if n := len([]rune(value)); n < width {
		return value + strings.Repeat(" ", width-n)
	}
	return value
}

// Summary は標準出力へ出す一覧である（従来の書式どおり）。
func (e *Evaluation) Summary() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Blue/Green 成立条件チェック: %s\n", e.InstanceID)
	fmt.Fprintf(&b, "収集日時: %s / 判定対象: %s\n", text(e.Metadata["collected_at"]), text(e.Metadata["target_engine_version"]))
	fmt.Fprintf(&b, "%s %s %s\n", pad("STATUS", 8), pad("ITEM", 30), "DETAIL")
	b.WriteString(strings.Repeat("-", 100) + "\n")
	for _, result := range e.Results {
		fmt.Fprintf(&b, "%s %s %s\n", pad(result.Status, 8), pad(result.Item, 30), result.Detail)
	}
	fmt.Fprintf(&b, "結果: STOP=%d, REVIEW=%d\n", e.Count("STOP"), e.Count("REVIEW"))
	b.WriteString(e.MySQL.summaryLine() + "\n")
	return b.String()
}

func escapeCell(value string) string {
	return strings.ReplaceAll(strings.ReplaceAll(value, "|", `\|`), "\n", " ")
}

// Report はゲート①の判断材料となる Markdown である。
func (e *Evaluation) Report() string {
	stops, reviews, passes := e.Count("STOP"), e.Count("REVIEW"), e.Count("PASS")
	verdict := fmt.Sprintf("**移行不可**（STOP %d 件）", stops)
	if stops == 0 {
		verdict = "**移行可能**（STOP なし）"
	}
	lines := []string{
		"# Blue/Green 成立条件チェック",
		"",
		"| 項目 | 値 |",
		"|---|---|",
		"| 対象インスタンス | `" + escapeCell(e.InstanceID) + "` |",
		"| エンジン | " + escapeCell(e.Engine) + " " + escapeCell(e.EngineVersion) + " |",
		"| インスタンスクラス | " + escapeCell(e.InstanceClass) + " |",
		"| 判定対象バージョン | " + escapeCell(text(e.Metadata["target_engine_version"])) + " |",
		"| 収集日時 | " + escapeCell(text(e.Metadata["collected_at"])) + " |",
		"| 判定 | " + verdict + " |",
		"",
		fmt.Sprintf("**PASS %d 件 / REVIEW %d 件 / STOP %d 件**", passes, reviews, stops),
		"",
		"## 判断材料と値",
		"",
		"判定の根拠になった観測値と、その値を読んだ収集ファイルを示す。",
		"",
		"| 判定 | 項目 | 観測値 | 取得元 |",
		"|---|---|---|---|",
	}
	for _, r := range e.Results {
		lines = append(lines, "| "+r.Status+" | "+escapeCell(r.Item)+" | "+escapeCell(r.Detail)+" | `"+escapeCell(r.Source)+"` |")
	}
	lines = append(lines, "")
	section := func(status, heading string) {
		if e.Count(status) == 0 {
			return
		}
		lines = append(lines, heading, "")
		for _, r := range e.Results {
			if r.Status == status {
				lines = append(lines, "- **"+r.Item+"** … "+r.Detail+"（`"+r.Source+"`）")
			}
		}
		lines = append(lines, "")
	}
	lines = append(lines, e.MySQL.reportLines()...)
	section("STOP", "## STOP — 解消しないと移行できない")
	section("REVIEW", "## REVIEW — 人の確認が要る")
	lines = append(lines, e.notes()...)
	lines = append(lines,
		"## この結果の読み方",
		"",
		"- **STOP が 1 件でも残る間は移行できない。**先に解消する",
		"- **REVIEW は自動判定では決められない項目である。**人が確認して可否を決める",
		"- このレポートは収集済み JSON だけから作る。**AWS へは接続していない**ため、",
		"  収集時点（上記の収集日時）の状態を示す。時間が空いたら再収集する",
		"- 項目の採番は `docs/phase-0-precheck.md` のチェックリストに対応する",
		"- MySQL 側の収集（接続先の状態・アップグレードチェッカー）が無い場合、関わる項目は REVIEW（未収集）になり、該当する節は「省略した」と明示している",
		"",
		"この結果をもとに、**移行できるか・どのインスタンスを対象にするか**を判断する。",
		"対象を決めたら次は移行設定の生成とそのレビューへ進む（`report-generation-flows.md`）。",
	)
	return strings.Join(lines, "\n") + "\n"
}
