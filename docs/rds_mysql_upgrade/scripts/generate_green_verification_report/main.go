// Step 4: 収集済み JSON と Step 2 の CloudFormation YAML から、Green 構成・
// パラメーター整合性を**検証**し、レポートを生成する。
//
// **検証とレポートはフラグで選ぶ。**両方を同時に行える。
//
//	--check          設定の宣言値と AWS の実状態を突き合わせ、不適合なら終了コード 1
//	--output FILE    Markdown レポートを書き出す
//
// どちらか一方、または両方を指定する。
//
// 突き合わせ（engine / instance class / パラメータグループの関連付けと適用状態 /
// ReplicaLag）は以前 verify_green.sh が担っていた。判定ロジックをレポート生成と
// 同じ場所へ集約し、**同じ材料から同じ結論が出る**ようにしてある。
//
// MySQL 実効値（--runtime-values）は任意である。リモートでは Green DB へ到達できない
// 構成もありうるため、渡さなければ該当列を「未収集」として出す。判定は AWS API から
// 取得した値で行うので、実効値の有無で判定内容は変わらない。
// 方針は decisions/implementation-language-policy.md にある。
//
// CloudFormation テンプレートの読み取り（短縮記法の正規化）は internal/cfn に委ねる。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"rds-mysql-upgrade/scripts/internal/cfn"
	"rds-mysql-upgrade/scripts/internal/greenstate"
)

type parameter struct {
	ParameterName  string `json:"ParameterName"`
	ParameterValue string `json:"ParameterValue"`
	Source         string `json:"Source"`
}

type parametersResponse struct {
	Parameters []parameter `json:"Parameters"`
}

// greenInstance は describe-db-instances の Green 側の必要項目である。
type greenInstance struct {
	Engine            string `json:"Engine"`
	EngineVersion     string `json:"EngineVersion"`
	DBInstanceClass   string `json:"DBInstanceClass"`
	DBParameterGroups []struct {
		DBParameterGroupName string `json:"DBParameterGroupName"`
		ParameterApplyStatus string `json:"ParameterApplyStatus"`
	} `json:"DBParameterGroups"`
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(2)
}

func readJSON(path string, destination any) {
	content, err := os.ReadFile(path)
	if err != nil {
		die("%s: %v", path, err)
	}
	if err := json.Unmarshal(content, destination); err != nil {
		die("%s: JSON を解析できません: %v", path, err)
	}
}

func readParameters(path string) map[string]parameter {
	var response parametersResponse
	readJSON(path, &response)
	result := make(map[string]parameter, len(response.Parameters))
	for _, value := range response.Parameters {
		result[value.ParameterName] = value
	}
	return result
}

func escape(value string) string {
	return strings.ReplaceAll(strings.ReplaceAll(value, "|", "\\|"), "\n", "<br>")
}

// safeParameterName は SQL へ埋め込める識別子だけを通す。
var safeParameterName = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

// printDeclaredParameterNames は テンプレートが宣言しているパラメータ名を並べる。
// 実値が決まっているものも組み込み関数のものも、名前としては同じように必要である。
func printDeclaredParameterNames(templatePath string) {
	group, err := cfn.ReadDBParameterGroup(templatePath)
	if err != nil {
		die("%v", err)
	}
	names := make([]string, 0, len(group.Declared)+len(group.Unresolved))
	for name := range group.Declared {
		names = append(names, name)
	}
	for name := range group.Unresolved {
		names = append(names, name)
	}
	if len(names) == 0 {
		die("%s: パラメータが 1 つも宣言されていません。", templatePath)
	}
	sort.Strings(names)
	for _, name := range names {
		if !safeParameterName.MatchString(name) {
			die("%s: パラメータ名として扱えない文字が含まれます: %q", templatePath, name)
		}
		fmt.Println(name)
	}
}

// checkOutcome は 1 件の検証結果である。
type checkOutcome struct {
	name     string // 何を見たか
	expected string // 設定の宣言値（比較対象が無い検査では空）
	actual   string // AWS から取得した実状態
	ok       bool
	detail   string // 補足（不適合の理由など）
}

// verifyGreen は Green の構成が設定の宣言どおりかを突き合わせる。
// expect* が空の項目は「宣言が無い」ものとして検査を飛ばす。
func verifyGreen(instance greenInstance, expectEngineVersion, expectInstanceClass, expectParameterGroup string) []checkOutcome {
	outcomes := make([]checkOutcome, 0, 4)

	if expectEngineVersion != "" {
		// RDS の自動マイナーバージョンアップグレードを吸収するため前方一致で見る
		// （宣言 8.4.10 に対し実体 8.4.10 は一致。8.0.x なら不一致）。
		ok := strings.HasPrefix(instance.EngineVersion, expectEngineVersion)
		outcomes = append(outcomes, checkOutcome{
			name: "Green のエンジンバージョン", expected: expectEngineVersion,
			actual: instance.EngineVersion, ok: ok,
			detail: "宣言値で始まること（パッチ差分は許容）",
		})
	}

	if expectInstanceClass != "" {
		ok := instance.DBInstanceClass == expectInstanceClass
		outcomes = append(outcomes, checkOutcome{
			name: "Green のインスタンスクラス", expected: expectInstanceClass,
			actual: instance.DBInstanceClass, ok: ok,
		})
	}

	if expectParameterGroup != "" {
		applyStatus := ""
		for _, group := range instance.DBParameterGroups {
			if group.DBParameterGroupName == expectParameterGroup {
				applyStatus = group.ParameterApplyStatus
				break
			}
		}
		associated := applyStatus != ""
		actual := applyStatus
		if !associated {
			associated = false
			actual = "関連付けなし"
			names := make([]string, 0, len(instance.DBParameterGroups))
			for _, group := range instance.DBParameterGroups {
				names = append(names, group.DBParameterGroupName)
			}
			outcomes = append(outcomes, checkOutcome{
				name: "Green のパラメータグループ関連付け", expected: expectParameterGroup,
				actual: actual, ok: false,
				detail: "実際に関連付いているのは " + strings.Join(names, ", "),
			})
		} else {
			outcomes = append(outcomes, checkOutcome{
				name: "Green のパラメータグループ関連付け", expected: expectParameterGroup,
				actual: expectParameterGroup, ok: true,
			})
			// 関連付いていても、適用が完了していなければ値は反映されていない。
			outcomes = append(outcomes, checkOutcome{
				name: "パラメータグループの適用状態", expected: "in-sync",
				actual: applyStatus, ok: applyStatus == "in-sync",
			})
		}
	}

	return outcomes
}

// verifyReplicaLag は Green のレプリカ遅延が解消していることを確かめる。
// データポイントが無い場合は「確認できていない」ため不適合とする。
func verifyReplicaLag(datapoints []float64) checkOutcome {
	if len(datapoints) == 0 {
		return checkOutcome{
			name: "レプリカ遅延", expected: "0 秒", actual: "データポイントなし", ok: false,
			detail: "メトリクスが未取得である。Green の作成直後は数分待ってから再実行する",
		}
	}
	maximum := datapoints[0]
	for _, point := range datapoints[1:] {
		if point > maximum {
			maximum = point
		}
	}
	return checkOutcome{
		name: "レプリカ遅延", expected: "0 秒",
		actual: fmt.Sprintf("%.3f 秒", maximum), ok: maximum <= 0,
		detail: "直近 10 分・1 分粒度の最大値",
	}
}

func main() {
	// collect_green_state が書き出したディレクトリ。指定すると下の 6 つの JSON は
	// このディレクトリの既定の名前から読む（個別に指定した場合はそちらを優先する）。
	inputDir := flag.String("input-dir", "", "collect_green_state の出力ディレクトリ")
	templatePath := flag.String("template", "", "CloudFormation YAML")
	greenInstancePath := flag.String("green-instance", "", "Green DB instance JSON")
	deploymentPath := flag.String("deployment", "", "Blue/Green deployment JSON")
	userParametersPath := flag.String("user-parameters", "", "Source=user parameter JSON")
	systemParametersPath := flag.String("system-parameters", "", "Source=system parameter JSON")
	allParametersPath := flag.String("all-parameters", "", "all parameter JSON")
	replicaLagPath := flag.String("replica-lag", "", "ReplicaLag JSON")
	runtimeValuesPath := flag.String("runtime-values", "", "optional MySQL runtime values JSON")
	outputPath := flag.String("output", "", "Markdown レポートの出力先（--check と併用可）")
	// 設定ファイルの宣言値。verify_green.sh が config から解決して渡す。
	// 空にした項目はその検査を行わない。
	expectEngineVersion := flag.String("expect-engine-version", "", "設定の target_engine_version（前方一致で照合）")
	expectInstanceClass := flag.String("expect-instance-class", "", "設定の target_db_instance_class")
	expectParameterGroup := flag.String("expect-parameter-group", "", "設定の target_db_parameter_group_name")
	check := flag.Bool("check", false, "宣言値と実状態を突き合わせ、不適合なら終了コード 1 を返す")
	// Step 4 の実効値収集が、問い合わせ対象のパラメータ名を得るために使う。
	// 同じバイナリに入れておけば、実行側（VerifyGreen）へ Go を持ち込まずに済む。
	listParameterNames := flag.Bool("list-parameter-names", false,
		"print the parameter names declared in --template, one per line, then exit")
	flag.Parse()

	if *listParameterNames {
		if *templatePath == "" {
			die("--template is required with --list-parameter-names.")
		}
		printDeclaredParameterNames(*templatePath)
		return
	}

	// --input-dir があれば、個別に指定されていない入力を既定の名前で補う。
	// ファイル名は collect_green_state（scripts/internal/greenstate）と揃える。
	if *inputDir != "" {
		for _, input := range []struct {
			path *string
			file string
		}{
			{greenInstancePath, greenstate.GreenInstanceFile},
			{deploymentPath, greenstate.DeploymentFile},
			{userParametersPath, greenstate.UserParametersFile},
			{systemParametersPath, greenstate.SystemParametersFile},
			{allParametersPath, greenstate.AllParametersFile},
			{replicaLagPath, greenstate.ReplicaLagFile},
		} {
			if *input.path == "" {
				*input.path = filepath.Join(*inputDir, input.file)
			}
		}
	}

	for name, value := range map[string]string{
		"template": *templatePath, "green-instance": *greenInstancePath,
		"deployment": *deploymentPath, "user-parameters": *userParametersPath,
		"system-parameters": *systemParametersPath, "all-parameters": *allParametersPath,
		"replica-lag": *replicaLagPath,
	} {
		if value == "" {
			die("--%s is required.", name)
		}
	}
	// 検証だけ・レポートだけ・両方、のいずれかである。何もしない指定は誤りとして弾く。
	if *outputPath == "" && !*check {
		die("--output か --check の少なくとも一方を指定してください。")
	}

	// CloudFormation の Resources から DBParameterGroup を探し、YAML 上の宣言値を取得する。
	// 値が組み込み関数（Ref / Fn::*）の項目は、CloudFormation のパラメータ解決なしには
	// 実値が決まらない。比較すると誤ったドリフトになるため、比較対象から外して明示する。
	group, err := cfn.ReadDBParameterGroup(*templatePath)
	if err != nil {
		die("%v", err)
	}
	expected := group.Declared
	unresolved := group.Unresolved

	user := readParameters(*userParametersPath)
	system := readParameters(*systemParametersPath)
	all := readParameters(*allParametersPath)
	runtime := map[string]string{}
	if *runtimeValuesPath != "" {
		var result struct {
			Parameters map[string]string `json:"Parameters"`
		}
		readJSON(*runtimeValuesPath, &result)
		runtime = result.Parameters
	}

	var greenResult struct {
		DBInstances []greenInstance `json:"DBInstances"`
	}
	readJSON(*greenInstancePath, &greenResult)
	if len(greenResult.DBInstances) == 0 {
		die("%s: DBInstances が空です。", *greenInstancePath)
	}
	instance := greenResult.DBInstances[0]

	var deploymentResult struct {
		BlueGreenDeployments []struct {
			BlueGreenDeploymentIdentifier string `json:"BlueGreenDeploymentIdentifier"`
			Status                        string `json:"Status"`
			Target                        string `json:"Target"`
		} `json:"BlueGreenDeployments"`
	}
	readJSON(*deploymentPath, &deploymentResult)
	if len(deploymentResult.BlueGreenDeployments) == 0 {
		die("%s: BlueGreenDeployments が空です。", *deploymentPath)
	}
	deployment := deploymentResult.BlueGreenDeployments[0]

	var lagResult struct {
		Datapoints []struct {
			Maximum float64 `json:"Maximum"`
		} `json:"Datapoints"`
	}
	readJSON(*replicaLagPath, &lagResult)
	lagMaximums := make([]float64, 0, len(lagResult.Datapoints))
	for _, point := range lagResult.Datapoints {
		lagMaximums = append(lagMaximums, point.Maximum)
	}

	// --- 突き合わせ ---------------------------------------------------------
	// **--check のときだけ行う。**レポートだけが欲しい場合（収集済みファイルから
	// 後で読み物を作り直す等）に、判定で落としたくないためである。
	// 実施した場合は結果をレポートにも載せる。
	// 「レポートの内容」と「終了コード」が食い違わないようにするためである。
	var outcomes []checkOutcome
	if *check {
		outcomes = verifyGreen(instance, *expectEngineVersion, *expectInstanceClass, *expectParameterGroup)
		outcomes = append(outcomes, verifyReplicaLag(lagMaximums))
	}

	names := map[string]bool{}
	for name := range expected {
		names[name] = true
	}
	for name := range user {
		names[name] = true
	}
	for name := range runtime {
		names[name] = true
	}
	for name := range unresolved {
		names[name] = true
	}
	orderedNames := make([]string, 0, len(names))
	for name := range names {
		orderedNames = append(orderedNames, name)
	}
	sort.Strings(orderedNames)

	// --output を省略した場合はレポートを書かず、検証だけを行う。
	fprintln := func(format string, args ...any) {}
	if *outputPath != "" {
		output, err := os.Create(*outputPath)
		if err != nil {
			die("%s: %v", *outputPath, err)
		}
		defer output.Close()
		fprintln = func(format string, args ...any) { fmt.Fprintf(output, format+"\n", args...) }
	}
	fprintln("# Green 構成・パラメーター検証レポート")
	fprintln("")
	fprintln("このレポートは、Step 2 の CloudFormation YAML、RDS DB パラメータグループの取得結果、および Green DB の関連付け状態を比較したものである。")
	fprintln("")
	// 突き合わせの結果を最初に出す。読む人が最初に知りたいのは可否である。
	if len(outcomes) > 0 {
		failed := 0
		for _, outcome := range outcomes {
			if !outcome.ok {
				failed++
			}
		}
		fprintln("## 0. 検証結果")
		fprintln("")
		if failed == 0 {
			fprintln("**すべて適合**（%d 件）", len(outcomes))
		} else {
			fprintln("**不適合 %d 件 / %d 件**", failed, len(outcomes))
		}
		fprintln("")
		fprintln("| 判定 | 検査 | 宣言値 | 実状態 | 備考 |")
		fprintln("|---|---|---|---|---|")
		for _, outcome := range outcomes {
			verdict := "適合"
			if !outcome.ok {
				verdict = "**不適合**"
			}
			expectedCell := outcome.expected
			if expectedCell == "" {
				expectedCell = "—"
			}
			detail := outcome.detail
			if detail == "" {
				detail = "—"
			}
			fprintln("| %s | %s | %s | %s | %s |",
				verdict, escape(outcome.name), escape(expectedCell), escape(outcome.actual), escape(detail))
		}
		fprintln("")
	}
	fprintln("## 1. Blue/Green Deployment と Green DB の状態")
	fprintln("")
	fprintln("- Deployment: `%s` / `%s`", deployment.BlueGreenDeploymentIdentifier, deployment.Status)
	fprintln("- Green DB ARN: `%s`", deployment.Target)
	fprintln("- Green engine: `%s %s`", instance.Engine, instance.EngineVersion)
	fprintln("- Green instance class: `%s`", instance.DBInstanceClass)
	for _, group := range instance.DBParameterGroups {
		fprintln("- Associated DB parameter group: `%s` / apply status: `%s`", group.DBParameterGroupName, group.ParameterApplyStatus)
	}
	fprintln("")
	fprintln("## 2. パラメーターグループ設定と YAML の一致")
	fprintln("")
	fprintln("| Parameter | CloudFormation YAML の宣言値 | RDS PG Source=user | 比較バリデーション | RDS PG Source=system | MySQL 実効値 | RDS PG が返す Source |")
	fprintln("|---|---|---|---|---|---|---|")
	for _, name := range orderedNames {
		yamlValue, yamlExists := expected[name]
		userValue, userExists := user[name]
		systemValue := system[name]
		allValue := all[name]
		result := "RDS PG のみ（YAML 外の user 定義）"
		if intrinsic, isUnresolved := unresolved[name]; isUnresolved {
			result = "比較不能（" + intrinsic + "）"
			yamlValue = intrinsic + "（未解決）"
		} else if yamlExists && userExists {
			if yamlValue == userValue.ParameterValue {
				result = "一致"
			} else {
				result = "不一致"
			}
		} else if yamlExists {
			result = "YAML のみ（RDS PG に未反映）"
		}
		runtimeValue, runtimeExists := runtime[name]
		if !runtimeExists {
			runtimeValue = "未収集"
		}
		fprintln("| %s | %s | %s | %s | %s | %s | %s |", escape(name), escape(yamlValue), escape(userValue.ParameterValue), result, escape(systemValue.ParameterValue), escape(runtimeValue), escape(allValue.Source))
	}
	fprintln("")
	fprintln("## 3. RDS が返す値の読み方")
	fprintln("")
	fprintln("- **RDS PG Source=user** は、カスタムパラメーターグループへ明示設定された値である。CloudFormation YAML との一致だけを比較バリデーションの対象とする。")
	fprintln("- **RDS PG Source=system** は、RDS が system 由来としてパラメーターグループ API で返した値である。インスタンスタイプ等により RDS が決める対象を確認する補助情報である。")
	fprintln("- **MySQL 実効値** は Green DB へ MySQL クライアントで接続し、`performance_schema.global_variables` から収集した値である。RDS の算出・上限調整を含みうるため、YAML／Source=user とは比較バリデーションしない。")
	fprintln("")
	fprintln("## 4. レプリカ同期")
	fprintln("")
	if len(lagResult.Datapoints) == 0 {
		fprintln("- ReplicaLag: データポイントなし（判定失敗）")
	} else {
		maximum := lagResult.Datapoints[0].Maximum
		for _, point := range lagResult.Datapoints[1:] {
			if point.Maximum > maximum {
				maximum = point.Maximum
			}
		}
		// Ruby 版と同じ書式にする（%v だと 0、Ruby の Float#to_s だと 0.0 になり食い違う）。
		fprintln("- ReplicaLag（直近 10 分・1 分粒度の最大値）: `%.3f` 秒", maximum)
	}
	fprintln("")
	fprintln("## レポートの利用方法")
	fprintln("")
	fprintln("- YAML と RDS PG Source=user の差分は構成ドリフトとして扱う。MySQL 実効値・算出値の妥当性は、インスタンスサイズと負荷条件を踏まえて人が判断する。")

	drift := make([]string, 0)
	for _, name := range orderedNames {
		// 組み込み関数で宣言された項目は実値が決まらないため、ドリフト判定から外す。
		if _, isUnresolved := unresolved[name]; isUnresolved {
			continue
		}
		yamlValue, yamlExists := expected[name]
		userValue, userExists := user[name]
		if (yamlExists && userExists && yamlValue != userValue.ParameterValue) || (yamlExists && !userExists) || (!yamlExists && userExists) {
			drift = append(drift, name)
		}
	}

	// --- 終了コード ---------------------------------------------------------
	// 不適合は「レポートに書いて終わり」にしない。**必ず終了コードへ反映する。**
	// これを CI のジョブ失敗としてそのまま扱う。
	failed := false
	for _, outcome := range outcomes {
		if outcome.ok {
			continue
		}
		failed = true
		fmt.Fprintf(os.Stderr, "不適合: %s（宣言 %q / 実状態 %q）\n", outcome.name, outcome.expected, outcome.actual)
		if outcome.detail != "" {
			fmt.Fprintf(os.Stderr, "        %s\n", outcome.detail)
		}
	}
	if len(drift) > 0 {
		failed = true
		fmt.Fprintf(os.Stderr, "CloudFormation YAML と RDS PG Source=user の不一致: %s\n", strings.Join(drift, ", "))
	}
	if failed {
		os.Exit(1)
	}
}
