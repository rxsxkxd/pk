// Blue/Green 設定生成用に、RDS DB インスタンスの事実情報を収集する。
//
// AWS API は rds describe-db-instances（読み取り）だけを使用し、変更操作は行わない。
// 「収集と判定を分離する」というリポジトリの方針に従い、ここでは判定を一切行わず、
// 応答へ収集時のリージョンだけをメタデータとして付ける。
//
// AWS SDK ではなく AWS CLI を exec する。理由は次の三つである。
//   - 認証の解決（named profile、SSO、STS の一時認証情報、環境変数）を AWS CLI に委ね、
//     リポジトリ全体で認証経路を 1 本に保てる
//   - go.mod への依存追加が不要で、yaml.v3 だけの現状を崩さない
//   - PATH 上の aws を差し替えるだけでテストからモックできる
//
// 実行: go run ./collect_rds_instance_inventory --region REGION --output FILE [--profile PROFILE]
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// describeResponse は describe-db-instances の応答のうち、必要な部分だけを見る。
// DBInstances の各要素は json.RawMessage で保持し、再エンコードで値を変えない。
type describeResponse struct {
	DBInstances []json.RawMessage `json:"DBInstances"`
}

// instanceParameterGroups は、パラメータグループ名を取り出すための最小の射影である。
type instanceParameterGroups struct {
	DBParameterGroups []struct {
		DBParameterGroupName string `json:"DBParameterGroupName"`
	} `json:"DBParameterGroups"`
}

// parametersResponse は describe-db-parameters の応答のうち、必要な部分だけを見る。
type parametersResponse struct {
	Parameters []struct {
		ParameterName  string `json:"ParameterName"`
		ParameterValue string `json:"ParameterValue"`
		Source         string `json:"Source"`
	} `json:"Parameters"`
}

// parameterGroupFacts は、確認用に採取するパラメータグループの実値である。
// time_zone は 8.0 → 8.4 で挙動差の論点になるため（reference/mysql-timezone*.md）、
// 切替の前後で変わらないことを人が確認できるよう収集しておく。
// Source は値の由来（user / system / engine-default）で、engine-default なら
// パラメータグループでは未設定である。
type parameterGroupFacts struct {
	TimeZone       string `json:"TimeZone"`
	TimeZoneSource string `json:"TimeZoneSource"`
}

// inventory は生成器が読む収集結果である。カタログに aws_region を重複記載せず、
// 生成先設定の aws_region をここから決めるためにリージョンを持つ。
type inventory struct {
	AwsRegion       string                         `json:"aws_region"`
	DBInstances     []json.RawMessage              `json:"DBInstances"`
	ParameterGroups map[string]parameterGroupFacts `json:"ParameterGroups"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	region := flag.String("region", "", "収集対象の AWS リージョン（必須）")
	profile := flag.String("profile", "", "AWS CLI の named profile（省略可）")
	output := flag.String("output", "", "収集結果の出力先 JSON（必須）")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr,
			"Usage: collect_rds_instance_inventory --region REGION --output FILE [--profile PROFILE]")
		flag.PrintDefaults()
	}
	flag.Parse()

	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "Unknown argument: %s\n", flag.Arg(0))
		flag.Usage()
		os.Exit(2)
	}
	if *region == "" || *output == "" {
		flag.Usage()
		os.Exit(2)
	}

	// [読み取り / レビュー注記]
	// DBInstanceIdentifier、Engine、EngineVersion、DBInstanceClass、関連付く
	// DBParameterGroups を含む DB インスタンス一覧を取得する。生成スクリプトはこの結果から
	// 移行元のエンジン major.minor とパラメータグループ名を補完し、カタログで
	// db_instance_class を省略した場合の踏襲値としても使う。
	response, err := describeDBInstances(*region, *profile)
	if err != nil {
		return err
	}

	// [読み取り / レビュー注記]
	// 各インスタンスに関連付くパラメータグループの time_zone 実値を採取する。
	// 判定はせず、生成結果へ確認用の項目として載せるだけである。
	parameterGroups, err := collectParameterGroupFacts(*region, *profile, response.DBInstances)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(*output), 0o755); err != nil {
		return err
	}
	collected := inventory{
		AwsRegion:       *region,
		DBInstances:     response.DBInstances,
		ParameterGroups: parameterGroups,
	}
	if err := writeJSON(*output, collected); err != nil {
		return err
	}
	fmt.Printf("Collected RDS instance inventory: %s\n", *output)
	return nil
}

// describeDBInstances は AWS CLI の読み取り API を 1 回だけ呼び、応答を検証する。
func describeDBInstances(region, profile string) (*describeResponse, error) {
	output, err := awsJSON(region, profile, "rds", "describe-db-instances")
	if err != nil {
		return nil, err
	}

	var response describeResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, fmt.Errorf("describe-db-instances response is not valid JSON: %w", err)
	}
	// 空配列は「対象なし」として通す。キー自体が無い応答だけを異常として扱う。
	if response.DBInstances == nil {
		return nil, fmt.Errorf("describe-db-instances response has no DBInstances array")
	}
	return &response, nil
}

// awsJSON は AWS CLI の読み取り API を 1 回呼び、標準出力の JSON を返す。
// リージョンと named profile の付与、失敗時の stderr 伝播をここに集約する。
func awsJSON(region, profile string, arguments ...string) ([]byte, error) {
	args := []string{"--region", region}
	if profile != "" {
		args = append(args, "--profile", profile)
	}
	args = append(args, arguments...)
	args = append(args, "--output", "json")

	command := exec.Command("aws", args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		called := strings.Join(arguments, " ")
		if stderr.Len() > 0 {
			return nil, fmt.Errorf("aws %s failed: %w: %s", called, err, stderr.String())
		}
		return nil, fmt.Errorf("aws %s failed: %w", called, err)
	}
	return stdout.Bytes(), nil
}

// collectParameterGroupFacts は、インスタンスに関連付く全パラメータグループについて
// time_zone の実値を 1 回ずつ読む。同じグループを複数インスタンスが共有していても
// API 呼び出しは 1 回で済ませる。
func collectParameterGroupFacts(region, profile string, instances []json.RawMessage) (map[string]parameterGroupFacts, error) {
	facts := map[string]parameterGroupFacts{}
	for _, raw := range instances {
		var projection instanceParameterGroups
		if err := json.Unmarshal(raw, &projection); err != nil {
			return nil, fmt.Errorf("DBInstances element is not an object: %w", err)
		}
		for _, group := range projection.DBParameterGroups {
			name := group.DBParameterGroupName
			if name == "" {
				continue
			}
			if _, done := facts[name]; done {
				continue
			}
			timeZone, source, err := describeTimeZone(region, profile, name)
			if err != nil {
				return nil, err
			}
			facts[name] = parameterGroupFacts{TimeZone: timeZone, TimeZoneSource: source}
		}
	}
	return facts, nil
}

// describeTimeZone は 1 つのパラメータグループの time_zone を読む。
// パラメータが応答に現れない場合は空文字を返す（判定は呼び出し側でも行わない）。
func describeTimeZone(region, profile, parameterGroupName string) (string, string, error) {
	output, err := awsJSON(region, profile,
		"rds", "describe-db-parameters",
		"--db-parameter-group-name", parameterGroupName)
	if err != nil {
		return "", "", err
	}
	var response parametersResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return "", "", fmt.Errorf(
			"describe-db-parameters response for %s is not valid JSON: %w", parameterGroupName, err)
	}
	for _, parameter := range response.Parameters {
		if parameter.ParameterName == "time_zone" {
			return parameter.ParameterValue, parameter.Source, nil
		}
	}
	return "", "", nil
}

// writeJSON は同一ディレクトリの一時ファイルへ書いてから rename する。
// 途中で失敗しても出力先に壊れた JSON を残さない。
func writeJSON(path string, value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')

	temporary, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)

	if _, err := temporary.Write(encoded); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	// CreateTemp は 0600 で作る。収集結果は人がレビューする事実情報で秘匿値を含まないため、
	// 通常のファイルと同じ 0644 へ直す。
	if err := os.Chmod(temporaryPath, 0o644); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}
