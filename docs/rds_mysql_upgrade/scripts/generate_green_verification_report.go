// Step 4: 収集済み JSON と Step 2 の CloudFormation YAML から、Green 構成・
// パラメーター整合性レポートを生成する。Ruby 版は後方互換のため維持する。
//
// 依存: gopkg.in/yaml.v3（ビルド方法・依存管理の導入は別途実施する）。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type parameter struct {
	ParameterName  string `json:"ParameterName"`
	ParameterValue string `json:"ParameterValue"`
	Source         string `json:"Source"`
}

type parametersResponse struct {
	Parameters []parameter `json:"Parameters"`
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

func main() {
	templatePath := flag.String("template", "", "CloudFormation YAML")
	greenInstancePath := flag.String("green-instance", "", "Green DB instance JSON")
	deploymentPath := flag.String("deployment", "", "Blue/Green deployment JSON")
	userParametersPath := flag.String("user-parameters", "", "Source=user parameter JSON")
	systemParametersPath := flag.String("system-parameters", "", "Source=system parameter JSON")
	allParametersPath := flag.String("all-parameters", "", "all parameter JSON")
	replicaLagPath := flag.String("replica-lag", "", "ReplicaLag JSON")
	runtimeValuesPath := flag.String("runtime-values", "", "optional MySQL runtime values JSON")
	outputPath := flag.String("output", "", "report Markdown")
	flag.Parse()

	for name, value := range map[string]string{
		"template": *templatePath, "green-instance": *greenInstancePath,
		"deployment": *deploymentPath, "user-parameters": *userParametersPath,
		"system-parameters": *systemParametersPath, "all-parameters": *allParametersPath,
		"replica-lag": *replicaLagPath, "output": *outputPath,
	} {
		if value == "" {
			die("--%s is required.", name)
		}
	}

	// CloudFormation の Resources から DBParameterGroup を探し、YAML 上の宣言値を取得する。
	var template map[string]any
	content, err := os.ReadFile(*templatePath)
	if err != nil {
		die("%s: %v", *templatePath, err)
	}
	if err := yaml.Unmarshal(content, &template); err != nil {
		die("%s: YAML を解析できません: %v", *templatePath, err)
	}
	resources, ok := template["Resources"].(map[string]any)
	if !ok {
		die("%s: Resources が見つかりません。", *templatePath)
	}
	expected := map[string]string{}
	found := false
	for _, raw := range resources {
		resource, ok := raw.(map[string]any)
		if !ok || resource["Type"] != "AWS::RDS::DBParameterGroup" {
			continue
		}
		found = true
		properties, _ := resource["Properties"].(map[string]any)
		parameters, _ := properties["Parameters"].(map[string]any)
		for name, value := range parameters {
			expected[name] = fmt.Sprint(value)
		}
		break
	}
	if !found {
		die("%s: AWS::RDS::DBParameterGroup が見つかりません。", *templatePath)
	}

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
		DBInstances []struct {
			Engine            string `json:"Engine"`
			EngineVersion     string `json:"EngineVersion"`
			DBInstanceClass   string `json:"DBInstanceClass"`
			DBParameterGroups []struct {
				DBParameterGroupName string `json:"DBParameterGroupName"`
				ParameterApplyStatus string `json:"ParameterApplyStatus"`
			} `json:"DBParameterGroups"`
		} `json:"DBInstances"`
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
	orderedNames := make([]string, 0, len(names))
	for name := range names {
		orderedNames = append(orderedNames, name)
	}
	sort.Strings(orderedNames)

	output, err := os.Create(*outputPath)
	if err != nil {
		die("%s: %v", *outputPath, err)
	}
	defer output.Close()
	fprintln := func(format string, args ...any) { fmt.Fprintf(output, format+"\n", args...) }
	fprintln("# Green 構成・パラメーター検証レポート")
	fprintln("")
	fprintln("このレポートは、Step 2 の CloudFormation YAML、RDS DB パラメータグループの取得結果、および Green DB の関連付け状態を比較したものである。")
	fprintln("")
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
		if yamlExists && userExists {
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
		fprintln("- ReplicaLag（直近 10 分・1 分粒度の最大値）: `%v` 秒", maximum)
	}
	fprintln("")
	fprintln("## レポートの利用方法")
	fprintln("")
	fprintln("- YAML と RDS PG Source=user の差分は構成ドリフトとして扱う。MySQL 実効値・算出値の妥当性は、インスタンスサイズと負荷条件を踏まえて人が判断する。")

	drift := make([]string, 0)
	for _, name := range orderedNames {
		yamlValue, yamlExists := expected[name]
		userValue, userExists := user[name]
		if (yamlExists && userExists && yamlValue != userValue.ParameterValue) || (yamlExists && !userExists) || (!yamlExists && userExists) {
			drift = append(drift, name)
		}
	}
	if len(drift) > 0 {
		fmt.Fprintf(os.Stderr, "CloudFormation YAML と RDS PG Source=user の不一致: %s\n", strings.Join(drift, ", "))
		os.Exit(1)
	}
}
