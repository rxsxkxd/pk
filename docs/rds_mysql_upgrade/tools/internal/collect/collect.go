// Package collect は RDS の事実情報を AWS から収集する。
//
// AWS API は読み取り（Describe*）だけを使用し、変更操作は行わない。
// 「収集と判定を分離する」というリポジトリの方針の、収集側にあたる。
// ここでは一切の判定を行わず、応答へ収集時のリージョンだけをメタデータとして付ける。
//
// AWS SDK ではなく AWS CLI を exec する。理由は次の三つである。
//   - 認証の解決（named profile、SSO、STS の一時認証情報、環境変数）を AWS CLI に委ね、
//     リポジトリ全体で認証経路を 1 本に保てる
//   - go.mod への依存追加が不要である
//   - PATH 上の aws を差し替えるだけでテストからモックできる
package collect

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"rds-mysql-upgrade/tools/internal/common"
)

// CollectedParameters は、確認用に採取するパラメータグループのパラメータ名である。
//
// time_zone は 8.0 → 8.4 で挙動差の論点になるため採取する
// （DEFAULT CURRENT_TIMESTAMP の datetime 列への影響: docs/references/mysql-timezone*.md）。
// 対象を増やすときはここへ足す。インベントリの構造は変わらない。
var CollectedParameters = []string{"time_zone"}

// Options は収集対象の指定である。Profile は空なら AWS CLI の既定解決に任せる。
type Options struct {
	Region  string
	Profile string
}

// Inventory は describe-db-instances と、見つかったパラメータグループごとの
// describe-db-parameters を呼び、インベントリを組み立てる。
func Inventory(options Options) (*common.Inventory, error) {
	// [読み取り / レビュー注記]
	// DBInstanceIdentifier、Engine、EngineVersion、DBInstanceClass、関連付く
	// DBParameterGroups を含む DB インスタンス一覧を取得する。生成側はこの結果から
	// 移行元のエンジン major.minor とパラメータグループ名を補完し、カタログで
	// db_instance_class を省略した場合の踏襲値としても使う。
	instances, err := describeDBInstances(options)
	if err != nil {
		return nil, err
	}

	// [読み取り / レビュー注記]
	// 各パラメータグループについて CollectedParameters の実値を採取する。判定はせず、
	// 生成結果へ確認用の項目として載せるだけである。
	parameterGroups, err := describeParameterGroups(options, instances)
	if err != nil {
		return nil, err
	}

	return &common.Inventory{
		AwsRegion:       options.Region,
		DBInstances:     instances,
		ParameterGroups: parameterGroups,
	}, nil
}

func describeDBInstances(options Options) ([]*common.DBInstance, error) {
	output, err := awsJSON(options, "rds", "describe-db-instances")
	if err != nil {
		return nil, err
	}
	var response struct {
		DBInstances []*common.DBInstance `json:"DBInstances"`
	}
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, fmt.Errorf("describe-db-instances response is not valid JSON: %w", err)
	}
	// 空配列は「対象なし」として通す。キー自体が無い応答だけを異常として扱う。
	if response.DBInstances == nil {
		return nil, fmt.Errorf("describe-db-instances response has no DBInstances array")
	}
	return response.DBInstances, nil
}

// describeParameterGroups は、インスタンスに関連付く全パラメータグループを 1 回ずつ読む。
// 同じグループを複数インスタンスが共有していても API 呼び出しは 1 回で済ませる。
func describeParameterGroups(options Options, instances []*common.DBInstance) (map[string]*common.ParameterGroupFacts, error) {
	facts := map[string]*common.ParameterGroupFacts{}
	for _, instance := range instances {
		if instance == nil {
			continue
		}
		for _, group := range instance.DBParameterGroups {
			name := group.DBParameterGroupName
			if name == "" {
				continue
			}
			if _, done := facts[name]; done {
				continue
			}
			found, err := describeParameters(options, name)
			if err != nil {
				return nil, err
			}
			facts[name] = found
		}
	}
	return facts, nil
}

// describeParameters は 1 つのパラメータグループから CollectedParameters を読む。
// 応答に現れないパラメータは採取しない（ここでも判定はしない）。
func describeParameters(options Options, parameterGroupName string) (*common.ParameterGroupFacts, error) {
	output, err := awsJSON(options,
		"rds", "describe-db-parameters", "--db-parameter-group-name", parameterGroupName)
	if err != nil {
		return nil, err
	}
	var response struct {
		Parameters []struct {
			ParameterName  string `json:"ParameterName"`
			ParameterValue string `json:"ParameterValue"`
			Source         string `json:"Source"`
		} `json:"Parameters"`
	}
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, fmt.Errorf(
			"describe-db-parameters response for %s is not valid JSON: %w", parameterGroupName, err)
	}
	wanted := map[string]bool{}
	for _, name := range CollectedParameters {
		wanted[name] = true
	}
	facts := &common.ParameterGroupFacts{Parameters: map[string]common.ParameterValue{}}
	for _, parameter := range response.Parameters {
		if wanted[parameter.ParameterName] {
			facts.Parameters[parameter.ParameterName] = common.ParameterValue{
				Value:  parameter.ParameterValue,
				Source: parameter.Source,
			}
		}
	}
	return facts, nil
}

// awsJSON は AWS CLI の読み取り API を 1 回呼び、標準出力の JSON を返す。
// リージョンと named profile の付与、失敗時の stderr 伝播をここに集約する。
func awsJSON(options Options, arguments ...string) ([]byte, error) {
	args := []string{"--region", options.Region}
	if options.Profile != "" {
		args = append(args, "--profile", options.Profile)
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
