// Package paramgen は Step 2（8.4 パラメータグループの生成）を担う。
//
//   - Collect  … 移行元 8.0 パラメータグループと 8.0 / 8.4 の既定値を AWS の読み取り API で集める
//   - Generate … 集めた JSON と移行ルール（config/mysql80-to-84-parameter-rules.yml）から、
//     CloudFormation テンプレートとレビュー用 Markdown を作る。**AWS を呼ばない**
//
// 移行ルールがパラメータの扱いの唯一の正本である。扱いを変えるときはこのコードではなく
// ルール YAML を編集する。「要レビュー」「生成不可」が残れば、呼び出し側が終了コード 1 を返す。
package paramgen

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"

	"rds-mysql-upgrade/tools/internal/awscli"
)

// ---------------------------------------------------------------------------
// 収集
// ---------------------------------------------------------------------------

// CollectOptions は収集の入力である。
type CollectOptions struct {
	Client               awscli.Client
	SourceParameterGroup string
	DBInstanceID         string // 任意。関連付けと適用状態も取る
	OutputDir            string
	Now                  func() time.Time
}

// Collect は生成に要る JSON を OutputDir へ書き出す。すべて読み取り API である。
func Collect(options CollectOptions) error {
	if options.Now == nil {
		options.Now = time.Now
	}
	client := options.Client
	save := func(name string) string { return filepath.Join(options.OutputDir, name) }
	for _, call := range []struct {
		file string
		args []string
	}{
		// [P1-01] 対象 8.0 パラメータグループの family・名前・説明。
		{"source-parameter-group.json", []string{"rds", "describe-db-parameter-groups", "--db-parameter-group-name", options.SourceParameterGroup}},
		// [P1-02] 利用者が明示設定した値（8.4 への反映候補と移行ルール照合の入力）。
		{"source-user-parameters.json", []string{"rds", "describe-db-parameters", "--db-parameter-group-name", options.SourceParameterGroup, "--source", "user"}},
		// [P1-03] RDS が system として返す値（engine default と区別してレポートに載せる）。
		{"source-system-parameters.json", []string{"rds", "describe-db-parameters", "--db-parameter-group-name", options.SourceParameterGroup, "--source", "system"}},
		// [P1-04] mysql8.0 ファミリーの engine default。
		{"mysql80-default-parameters.json", []string{"rds", "describe-engine-default-parameters", "--db-parameter-group-family", "mysql8.0"}},
		// [P1-05] mysql8.4 ファミリーの engine default（存否・変更可否・許容値・既定値）。
		{"mysql84-default-parameters.json", []string{"rds", "describe-engine-default-parameters", "--db-parameter-group-family", "mysql8.4"}},
	} {
		if err := client.JSON(save(call.file), nil, call.args...); err != nil {
			return err
		}
	}
	if options.DBInstanceID != "" {
		// [P1-06] 任意。現行 DB へのグループ関連付けと ParameterApplyStatus。
		if err := client.JSON(save("source-db-instance.json"), nil,
			"rds", "describe-db-instances", "--db-instance-identifier", options.DBInstanceID); err != nil {
			return err
		}
	}
	metadata, err := json.Marshal(struct {
		SourceParameterGroup string `json:"source_parameter_group"`
		CollectedAt          string `json:"collected_at"`
	}{options.SourceParameterGroup, options.Now().UTC().Format(time.RFC3339)})
	if err != nil {
		return err
	}
	return os.WriteFile(save("metadata.json"), append(metadata, '\n'), 0o644)
}

// ---------------------------------------------------------------------------
// ルール
// ---------------------------------------------------------------------------

// Rule は移行ルール 1 件である。値は YAML の型のまま持つ（文字列・数値・真偽）。
type Rule struct {
	Name              string
	Action            *string // nil なら未指定
	Target            string
	Value             any
	Rationale         *string
	SourceValue       any
	SourceRequired    bool
	TargetOnly        bool
	ReportCategory    string
	AdditionalTargets []AdditionalTarget
}

// AdditionalTarget は 1 つの旧パラメータから追加で設定する 8.4 パラメータである。
type AdditionalTarget struct {
	Target    string
	Value     any
	Rationale *string
}

func (r Rule) target() string {
	if r.Target != "" {
		return r.Target
	}
	return r.Name
}

func (r Rule) rationale() string {
	if r.Rationale == nil {
		return ""
	}
	return *r.Rationale
}

// ReadRules はルール YAML を**記述順を保って**読む（処理順と行の並びがこれで決まる）。
func ReadRules(path string) ([]Rule, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var root yaml.Node
	if err := yaml.Unmarshal(content, &root); err != nil {
		return nil, fmt.Errorf("%s: YAML を解析できない: %w", path, err)
	}
	if len(root.Content) == 0 {
		return nil, nil
	}
	rulesNode := mappingValue(root.Content[0], "rules")
	if rulesNode == nil {
		return nil, nil
	}
	var rules []Rule
	for i := 0; i+1 < len(rulesNode.Content); i += 2 {
		name := rulesNode.Content[i].Value
		var fields map[string]any
		if err := rulesNode.Content[i+1].Decode(&fields); err != nil {
			return nil, fmt.Errorf("%s: rules.%s を読めない: %w", path, name, err)
		}
		rule := Rule{Name: name, Value: fields["value"], SourceValue: fields["source_value"]}
		if action, ok := fields["action"]; ok && action != nil {
			text := stringOf(action)
			rule.Action = &text
		}
		rule.Target = stringOf(fields["target"])
		if rationale, ok := fields["rationale"]; ok && rationale != nil {
			text := stringOf(rationale)
			rule.Rationale = &text
		}
		rule.SourceRequired = truthy(fields["source_required"])
		rule.TargetOnly = truthy(fields["target_only"])
		rule.ReportCategory = stringOf(fields["report_category"])
		additional, _ := fields["additional_targets"].([]any)
		for _, entry := range additional {
			mapping, _ := entry.(map[string]any)
			target := AdditionalTarget{Target: stringOf(mapping["target"]), Value: mapping["value"]}
			if rationale, ok := mapping["rationale"]; ok && rationale != nil {
				text := stringOf(rationale)
				target.Rationale = &text
			}
			rule.AdditionalTargets = append(rule.AdditionalTargets, target)
		}
		rules = append(rules, rule)
	}
	return rules, nil
}

func mappingValue(node *yaml.Node, key string) *yaml.Node {
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			return node.Content[i+1]
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// 生成
// ---------------------------------------------------------------------------

// Options は生成の入力である。
type Options struct {
	InputDir    string
	OutputDir   string
	System      string
	Environment string
	RulesPath   string // レポートにもこの表記のまま載る
}

// Result は生成の結果である。
type Result struct {
	TemplatePath string
	ReportPath   string
	Generated    int
	Review       int
	Blocked      int
}

// MissingError は収集ファイルが無いことを示す。
type MissingError struct{ Name string }

func (e *MissingError) Error() string {
	return fmt.Sprintf("Missing %s; run collect_mysql84_parameter_inputs first.", e.Name)
}

// parameter は describe-* が返すパラメータ 1 件（値が無い項目は nil）。
type parameter map[string]any

func (p parameter) value() any { return p["ParameterValue"] }

type row struct {
	name, target, action, result, detail    string
	sourceValue, engineDefault80, default84 any
}

type state struct {
	options         Options
	metadata        map[string]any
	sourceGroup     map[string]any
	sourceUser      []parameter
	systemCollected bool
	system80        map[string]parameter
	default80       map[string]parameter
	default84       map[string]parameter
	rules           []Rule
	rows            []row
	generated       map[string]any
}

func readDocument(dir, name string) (map[string]any, error) {
	content, err := os.ReadFile(filepath.Join(dir, name))
	if os.IsNotExist(err) {
		return nil, &MissingError{Name: name}
	}
	if err != nil {
		return nil, err
	}
	var document map[string]any
	if err := json.Unmarshal(content, &document); err != nil {
		return nil, fmt.Errorf("%s: JSON を解析できない: %w", name, err)
	}
	return document, nil
}

func parameters(document map[string]any, keys ...string) []parameter {
	node := any(document)
	for _, key := range keys {
		mapping, _ := node.(map[string]any)
		node = mapping[key]
	}
	list, _ := node.([]any)
	result := make([]parameter, 0, len(list))
	for _, entry := range list {
		mapping, _ := entry.(map[string]any)
		result = append(result, parameter(mapping))
	}
	return result
}

func byName(list []parameter) map[string]parameter {
	result := make(map[string]parameter, len(list))
	for _, p := range list {
		result[stringOf(p["ParameterName"])] = p
	}
	return result
}

// Generate はテンプレートとレポートを書き出す。
func Generate(options Options) (*Result, error) {
	s := &state{options: options, generated: map[string]any{}}
	var err error
	if s.metadata, err = readDocument(options.InputDir, "metadata.json"); err != nil {
		return nil, err
	}
	groupDocument, err := readDocument(options.InputDir, "source-parameter-group.json")
	if err != nil {
		return nil, err
	}
	groups, _ := groupDocument["DBParameterGroups"].([]any)
	if len(groups) == 0 {
		return nil, fmt.Errorf("source-parameter-group.json: DBParameterGroups が空である")
	}
	s.sourceGroup, _ = groups[0].(map[string]any)
	userDocument, err := readDocument(options.InputDir, "source-user-parameters.json")
	if err != nil {
		return nil, err
	}
	s.sourceUser = parameters(userDocument, "Parameters")
	if _, statErr := os.Stat(filepath.Join(options.InputDir, "source-system-parameters.json")); statErr == nil {
		s.systemCollected = true
		systemDocument, err := readDocument(options.InputDir, "source-system-parameters.json")
		if err != nil {
			return nil, err
		}
		s.system80 = byName(parameters(systemDocument, "Parameters"))
	} else {
		s.system80 = map[string]parameter{}
	}
	for name, target := range map[string]*map[string]parameter{
		"mysql80-default-parameters.json": &s.default80, "mysql84-default-parameters.json": &s.default84,
	} {
		document, err := readDocument(options.InputDir, name)
		if err != nil {
			return nil, err
		}
		*target = byName(parameters(document, "EngineDefaults", "Parameters"))
	}
	if s.rules, err = ReadRules(options.RulesPath); err != nil {
		return nil, err
	}

	s.applyUserParameters()
	s.applyRemainingRules()

	instanceStatus := "未収集（--db-instance-id を指定して再収集可能）"
	if _, statErr := os.Stat(filepath.Join(options.InputDir, "source-db-instance.json")); statErr == nil {
		document, err := readDocument(options.InputDir, "source-db-instance.json")
		if err != nil {
			return nil, err
		}
		instanceStatus = "対象グループは関連付けられていない"
		instances, _ := document["DBInstances"].([]any)
		if len(instances) > 0 {
			instance, _ := instances[0].(map[string]any)
			associated, _ := instance["DBParameterGroups"].([]any)
			for _, entry := range associated {
				group, _ := entry.(map[string]any)
				if stringOf(group["DBParameterGroupName"]) == stringOf(s.sourceGroup["DBParameterGroupName"]) {
					instanceStatus = stringOf(group["ParameterApplyStatus"])
					break
				}
			}
		}
	}

	if err := os.MkdirAll(options.OutputDir, 0o755); err != nil {
		return nil, err
	}
	result := &Result{
		TemplatePath: filepath.Join(options.OutputDir, "mysql84-parameter-group.yaml"),
		ReportPath:   filepath.Join(options.OutputDir, "mysql80-to-mysql84-parameter-report.md"),
		Generated:    len(s.generated),
	}
	for _, r := range s.rows {
		switch r.result {
		case "BLOCKED":
			result.Blocked++
		case "REVIEW":
			result.Review++
		}
	}
	if err := os.WriteFile(result.TemplatePath, []byte(s.template()), 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(result.ReportPath, []byte(s.report(instanceStatus, result)), 0o644); err != nil {
		return nil, err
	}
	return result, nil
}

func (s *state) rule(name string) (Rule, bool) {
	for _, rule := range s.rules {
		if rule.Name == name {
			return rule, true
		}
	}
	return Rule{}, false
}

func modifiable(p parameter) bool { return p != nil && truthy(p["IsModifiable"]) }

func valueOf(p parameter) any {
	if p == nil {
		return nil
	}
	return p.value()
}

// applyUserParameters は Source=user の各値に移行ルールを当てる。ルールが無ければ、
// 8.4 に同名で存在し変更可能なら同じ値で反映する（copy）。
func (s *state) applyUserParameters() {
	for _, p := range s.sourceUser {
		name := stringOf(p["ParameterName"])
		value := p.value()
		rule, found := s.rule(name)
		if !found {
			action, rationale := "copy", "移行ルール未登録。Source=user の値を同名で反映する"
			rule = Rule{Name: name, Action: &action, Rationale: &rationale}
		}
		action := "review"
		if rule.Action != nil {
			action = *rule.Action
		}
		target := rule.target()
		targetParameter := s.default84[target]
		result, detail := "REVIEW", rule.rationale()
		base := row{name: name, sourceValue: value, engineDefault80: valueOf(s.default80[name]), target: target,
			default84: valueOf(targetParameter), action: action}

		// 値に依存する移行ルール（例: mysql_native_password を既定にしていた場合だけ適用する）。
		if rule.SourceValue != nil && !sameValue(value, rule.SourceValue) {
			base.result = "OMITTED"
			base.detail = fmt.Sprintf("Source=user=%s のため適用条件（%s）に該当しない", stringOf(value), stringOf(rule.SourceValue))
			s.rows = append(s.rows, base)
			continue
		}

		switch action {
		case "copy":
			if modifiable(targetParameter) {
				s.generated[target] = value
				result = "GENERATED"
			} else {
				result, detail = "BLOCKED", detail+" / 8.4 に存在しない、または変更不可"
			}
		case "force":
			if modifiable(targetParameter) {
				s.generated[target] = rule.Value
				result = "GENERATED"
				// 1 つの旧パラメータから複数の 8.4 パラメータを設定する場合の追加出力。
				for _, additional := range rule.AdditionalTargets {
					additionalParameter := s.default84[additional.Target]
					additionalDetail := detail
					if additional.Rationale != nil {
						additionalDetail = *additional.Rationale
					}
					extra := row{name: name, sourceValue: value, engineDefault80: valueOf(s.default80[name]),
						target: additional.Target, default84: valueOf(additionalParameter), action: "force"}
					if modifiable(additionalParameter) {
						s.generated[additional.Target] = additional.Value
						extra.result, extra.detail = "GENERATED", additionalDetail
					} else {
						extra.result, extra.detail = "BLOCKED", additionalDetail+" / 8.4 に存在しない、または変更不可"
					}
					s.rows = append(s.rows, extra)
				}
			} else {
				result, detail = "BLOCKED", detail+" / 8.4 に存在しない、または変更不可"
			}
		case "omit":
			result = "OMITTED"
		case "review":
			if modifiable(targetParameter) {
				s.generated[target] = value
				result, detail = "GENERATED", detail+" / Source=user の値を明示設定として反映する"
			} else {
				result, detail = "BLOCKED", detail+" / 8.4 に存在しない、または変更不可"
			}
		default:
			result, detail = "BLOCKED", "未知の action: "+action
		}
		base.result, base.detail = result, detail
		s.rows = append(s.rows, base)
	}
}

// applyRemainingRules は Source=user に無い force ルールと、target_only の 8.4 新規パラメータを処理する。
func (s *state) applyRemainingRules() {
	userNames := map[string]bool{}
	for _, p := range s.sourceUser {
		userNames[stringOf(p["ParameterName"])] = true
	}
	for _, rule := range s.rules {
		if userNames[rule.Name] || rule.Action == nil {
			continue
		}
		target := rule.target()
		p := s.default84[target]
		_, alreadyGenerated := s.generated[target]
		switch *rule.Action {
		case "force":
			if rule.SourceRequired || alreadyGenerated {
				continue
			}
			if modifiable(p) {
				s.generated[target] = rule.Value
				s.rows = append(s.rows, row{name: rule.Name, sourceValue: "(未設定)", engineDefault80: valueOf(s.default80[rule.Name]),
					target: target, default84: p.value(), action: "force", result: "GENERATED", detail: rule.rationale()})
			} else {
				s.rows = append(s.rows, row{name: rule.Name, sourceValue: "(未設定)", target: target, action: "force",
					result: "BLOCKED", detail: rule.rationale() + " / 8.4 に存在しない、または変更不可"})
			}
		case "review", "omit":
			// 8.0 の user 定義から同じ 8.4 パラメータを生成済みなら、重複する行は出さない。
			if !rule.TargetOnly || alreadyGenerated {
				continue
			}
			result := "OMITTED"
			if *rule.Action == "review" {
				result = "REVIEW"
			}
			s.rows = append(s.rows, row{name: rule.Name, sourceValue: "(8.4 新規)", target: target, default84: valueOf(p),
				action: *rule.Action, result: result, detail: rule.rationale()})
		}
	}
}

// template は CloudFormation テンプレートを Ruby の YAML.dump と同じ書式で書く。
func (s *state) template() string {
	name := strings.ToLower(s.options.System + "-" + s.options.Environment + "-mysql84-v1")
	var b strings.Builder
	line := func(indent int, key string, value any) {
		fmt.Fprintf(&b, "%s%s: %s\n", strings.Repeat(" ", indent), yamlString(key), yamlScalar(value))
	}
	head := func(indent int, key string) { fmt.Fprintf(&b, "%s%s:\n", strings.Repeat(" ", indent), yamlString(key)) }
	line(0, "AWSTemplateFormatVersion", "2010-09-09")
	line(0, "Description", "MySQL 8.4 DB parameter group only (generated; review before deployment)")
	head(0, "Resources")
	head(2, "Mysql84ParameterGroup")
	line(4, "Type", "AWS::RDS::DBParameterGroup")
	head(4, "Properties")
	line(6, "DBParameterGroupName", name)
	line(6, "Description", "MySQL 8.4 parameters for "+s.options.System+"/"+s.options.Environment)
	line(6, "Family", "mysql8.4")
	names := make([]string, 0, len(s.generated))
	for key := range s.generated {
		names = append(names, key)
	}
	sort.Strings(names)
	if len(names) == 0 {
		fmt.Fprintf(&b, "      Parameters: {}\n")
	} else {
		head(6, "Parameters")
		for _, key := range names {
			line(8, key, s.generated[key])
		}
	}
	head(6, "Tags")
	for _, tag := range [][2]string{{"System", s.options.System}, {"Environment", s.options.Environment}, {"ManagedBy", "CloudFormation"}} {
		fmt.Fprintf(&b, "      - Key: %s\n        Value: %s\n", yamlString(tag[0]), yamlString(tag[1]))
	}
	head(0, "Outputs")
	head(2, "DBParameterGroupName")
	head(4, "Value")
	// !Ref と等価な CloudFormation の長形式。
	line(6, "Ref", "Mysql84ParameterGroup")
	return b.String()
}

var resultLabel = map[string]string{
	"GENERATED": "生成済み",
	"OMITTED":   "設定対象外",
	"REVIEW":    "要レビュー",
	"BLOCKED":   "生成不可",
}

func markdownValue(value any) string {
	return strings.ReplaceAll(strings.ReplaceAll(stringOf(value), "|", `\|`), "\n", "<br>")
}

// system80Value は 8.0 の Source=system の値を返す。無ければ「なし」、旧形式の入力で
// 収集していなければ「未収集」。
func (s *state) system80Value(name string) string {
	if p, ok := s.system80[name]; ok && p.value() != nil {
		return stringOf(p.value())
	}
	if s.systemCollected {
		return "なし"
	}
	return "未収集"
}

func orElse(value any, fallback string) string {
	if value == nil {
		return fallback
	}
	return stringOf(value)
}

func (s *state) report(instanceStatus string, result *Result) string {
	var b strings.Builder
	puts := func(text string) { b.WriteString(text + "\n") }
	tableRow := func(values ...any) {
		cells := make([]string, len(values))
		for i, value := range values {
			cells[i] = markdownValue(value)
		}
		puts("| " + strings.Join(cells, " | ") + " |")
	}

	puts("# MySQL 8.0 → 8.4 パラメータ移行レポート")
	puts("")
	puts("- Source parameter group: `" + stringOf(s.sourceGroup["DBParameterGroupName"]) + "` (`" + stringOf(s.sourceGroup["DBParameterGroupFamily"]) + "`)")
	puts("- Source group apply status: `" + instanceStatus + "`")
	puts("- Collected at: `" + stringOf(s.metadata["collected_at"]) + "`")
	puts("- Rules: `" + s.options.RulesPath + "`")
	puts(fmt.Sprintf("- Generated parameters: `%d`", result.Generated))
	puts("")
	puts("## 値の由来")
	puts("")
	puts("- **8.0 engine default**: `describe-engine-default-parameters --db-parameter-group-family mysql8.0` が返すファミリーの既定値。`Source=system` の実効値ではない。")
	puts("- **8.0 Source=system**: `describe-db-parameters --source system` が現行カスタムグループについて返す、値の由来が RDS system であるパラメータ。該当値がない場合は `なし`、旧形式の入力で未収集の場合は `未収集` と表示する。")
	puts("- **8.0 Source=user**: `describe-db-parameters --source user` が返す明示設定値。")
	puts("- **8.4 engine default**: `describe-engine-default-parameters --db-parameter-group-family mysql8.4` が返すファミリーの既定値。Phase 1 では 8.4 DB に未関連付けのため、8.4 の `Source=system` は未取得・未確定である。")
	puts("")

	puts("## 1. 元の user 定義値")
	puts("")
	puts("`describe-db-parameters --source user` で取得した、8.0 カスタムパラメータグループの明示設定値である。")
	puts("")
	puts("| Parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | engine default との差分 |")
	puts("|---|---|---|---|---|")
	users := append([]parameter(nil), s.sourceUser...)
	sort.SliceStable(users, func(i, j int) bool {
		return stringOf(users[i]["ParameterName"]) < stringOf(users[j]["ParameterName"])
	})
	for _, p := range users {
		name := stringOf(p["ParameterName"])
		defaultValue := valueOf(s.default80[name])
		difference := "engine default から上書き"
		if stringOf(p.value()) == stringOf(defaultValue) {
			difference = "engine default と同一"
		}
		tableRow(name, p.value(), defaultValue, s.system80Value(name), difference)
	}
	if len(users) == 0 {
		puts("| (なし) |  |  |  |  |")
	}
	puts("")

	puts("## 2. リネーム以外の値変更・新規追加パラメーター")
	puts("")
	puts("名称変更（旧名から新名への `copy`）を除き、移行ルールに定義した値・仕様変更候補と MySQL 8.4 新規パラメーターを一覧化する。8.0 側で user 定義がない項目は、8.4 の既定値を採用するかをレビューする。")
	puts("")
	puts("| 区分 | 8.0 parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | 8.4 parameter | 8.4 engine default | Rule | 処理結果 | 判断理由（8.0 時点を含む） |")
	puts("|---|---|---|---|---|---|---|---|---|---|")
	var nonRename []Rule
	for _, rule := range s.rules {
		if rule.TargetOnly || rule.target() == rule.Name {
			nonRename = append(nonRename, rule)
		}
	}
	sort.SliceStable(nonRename, func(i, j int) bool { return nonRename[i].Name < nonRename[j].Name })
	for _, rule := range nonRename {
		target := rule.target()
		if _, generated := s.generated[target]; rule.TargetOnly && generated {
			continue
		}
		var matched *row
		for i := range s.rows {
			if s.rows[i].name == rule.Name {
				matched = &s.rows[i]
				break
			}
		}
		action := ""
		if rule.Action != nil {
			action = *rule.Action
		}
		category := rule.ReportCategory
		switch {
		case rule.TargetOnly:
			category = "8.4 新規"
		case action == "omit":
			category = "廃止・代替"
		case category == "":
			category = "値・仕様変更候補"
		}
		resultText := "8.0 user 定義なし"
		var sourceValue any
		if matched != nil {
			resultText, sourceValue = resultLabel[matched.result], matched.sourceValue
		}
		sourceDefault := valueOf(s.default80[rule.Name])
		systemValue := s.system80Value(rule.Name)
		var context string
		switch {
		case rule.TargetOnly:
			context = "8.0: パラメーターなし（8.4 新規）"
		case matched != nil && stringOf(matched.sourceValue) == stringOf(sourceDefault):
			context = "8.0: Source=user=" + stringOf(matched.sourceValue) + "（engine default と同一、Source=system=" + systemValue + "）"
		case matched != nil:
			context = "8.0: Source=user=" + stringOf(matched.sourceValue) + "（engine default=" + orElse(sourceDefault, "取得なし") + "、Source=system=" + systemValue + "）"
		default:
			context = "8.0: Source=user なし（engine default=" + orElse(sourceDefault, "取得なし") + "、Source=system=" + systemValue + "）"
		}
		rationale := context
		if rule.Rationale != nil {
			rationale = *rule.Rationale + " / " + context
		}
		tableRow(category, rule.Name, sourceValue, sourceDefault, systemValue, target,
			valueOf(s.default84[target]), action, resultText, rationale)
	}
	puts("")

	puts("## 3. 移行処理結果")
	puts("")
	puts("収集された user 定義と `target_only` ルールを、生成可否まで含めて記録する。未登録の user 定義は、8.4 に同名で存在し変更可能なら同じ値を生成し、それ以外は「生成不可」として検出する。")
	puts("")
	puts("| Source parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | 8.4 target | 8.4 engine default | 8.4 Source=user（生成値） | Rule | 処理結果 | 判断理由 |")
	puts("|---|---|---|---|---|---|---|---|---|---|")
	rows := append([]row(nil), s.rows...)
	// 同じ旧パラメータから複数行が出る場合（additional_targets）は、処理した順を保つ。
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].name < rows[j].name })
	for _, r := range rows {
		var generatedValue any
		if r.result == "GENERATED" {
			generatedValue = s.generated[r.target]
		}
		tableRow(r.name, r.sourceValue, r.engineDefault80, s.system80Value(r.name), r.target, r.default84,
			generatedValue, r.action, resultLabel[r.result], r.detail)
	}
	puts("")
	puts("## 判定")
	puts("")
	puts(fmt.Sprintf("- 生成不可: %d", result.Blocked))
	puts(fmt.Sprintf("- 要レビュー: %d", result.Review))
	puts("「要レビュー」または「生成不可」が残る場合、生成 YAML をデプロイしない。ルールを更新して再生成する。")
	return b.String()
}

// ---------------------------------------------------------------------------
// 値の扱い（Ruby の to_s / 真偽 / == に合わせる）
// ---------------------------------------------------------------------------

func stringOf(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case float64:
		if typed == float64(int64(typed)) {
			return fmt.Sprintf("%d", int64(typed))
		}
	}
	return fmt.Sprint(value)
}

func truthy(value any) bool {
	if value == nil {
		return false
	}
	if boolean, ok := value.(bool); ok {
		return boolean
	}
	return true
}

// sameValue は Ruby の == に合わせ、型が違えば一致しない（"1" と 1 は別物）。
func sameValue(a, b any) bool {
	as, aIsString := a.(string)
	bs, bIsString := b.(string)
	if aIsString || bIsString {
		return aIsString && bIsString && as == bs
	}
	return fmt.Sprint(a) == fmt.Sprint(b)
}
