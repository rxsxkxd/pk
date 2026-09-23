// Package greenstate は Step 4 の検証に必要な AWS の状態を収集し、
// 判定器（generate_green_verification_report）が読むファイル一式を書き出す。
//
// **収集だけを行い、判定はしない。**「収集と判定を分離する」という中核ルールに
// 従い、適合・不適合の判断は判定器の --check が行う。ここが返すエラーは
// 「収集できなかった」ことだけである（Deployment が無い・AVAILABLE でない等）。
//
// AWS は SDK ではなく AWS CLI を exec する。シェル版と同じコマンドを同じ引数で
// 叩くので、権限・プロファイル・リージョンの解決、VPC endpoint 経由の到達性が
// シェル版と変わらない。gem や SDK の追加も要らない。
//
// 以前は scripts/verify_green.sh が同じ処理をシェルで行っていた。シェル版は
// 「JSON を保存する呼び出し」と「--query で値だけを取り出す呼び出し」で
// 同じ API を二重に叩いていたが、ここでは JSON を 1 回取って自分で読む。
package greenstate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// 書き出すファイル名。判定器の --input-dir はこの名前を前提に読む。
// **名前を変えるときは判定器の既定値も同時に変える。**
const (
	SourceInstanceFile   = "source.json"
	DeploymentFile       = "deployment.json"
	GreenInstanceFile    = "green-db-instance.json"
	UserParametersFile   = "green-user-parameters.json"
	SystemParametersFile = "green-system-parameters.json"
	AllParametersFile    = "green-all-parameters.json"
	ReplicaLagFile       = "replica-lag.json"
)

// Options は収集の入力である。値はすべて設定ファイルから呼び出し側が解決して渡す。
type Options struct {
	Region               string
	Profile              string
	SourceInstanceID     string
	TargetParameterGroup string
	OutputDir            string
	ReplicaLagWindow     time.Duration
	Now                  func() time.Time // テストで時刻を固定するため
}

// Result は収集した結果のうち、呼び出し側（シェル）が続きで使う値である。
type Result struct {
	DeploymentID    string
	GreenInstanceID string
	GreenEndpoint   string
}

// Collect は Step 4 に必要な状態を集めてファイルへ書く。
func Collect(options Options) (*Result, error) {
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.ReplicaLagWindow == 0 {
		options.ReplicaLagWindow = 10 * time.Minute
	}
	if err := os.MkdirAll(options.OutputDir, 0o755); err != nil {
		return nil, fmt.Errorf("%s: 出力先を作れない: %w", options.OutputDir, err)
	}

	// [読み取り] 移行元の ARN を得る。Deployment を source で引き当てるためである。
	var source struct {
		DBInstances []struct {
			DBInstanceArn string `json:"DBInstanceArn"`
		} `json:"DBInstances"`
	}
	if err := call(options, SourceInstanceFile, &source,
		"rds", "describe-db-instances", "--db-instance-identifier", options.SourceInstanceID); err != nil {
		return nil, err
	}
	if len(source.DBInstances) == 0 || source.DBInstances[0].DBInstanceArn == "" {
		return nil, fmt.Errorf("移行元 %s の ARN を取得できない", options.SourceInstanceID)
	}
	sourceARN := source.DBInstances[0].DBInstanceArn

	// [読み取り] 移行元に対応する Blue/Green Deployment を引き当てる。
	// Deployment ID は設定ファイルに持たず、毎回 AWS から引き当てる（中核ルール）。
	var deployments struct {
		BlueGreenDeployments []struct {
			BlueGreenDeploymentIdentifier string `json:"BlueGreenDeploymentIdentifier"`
			Target                        string `json:"Target"`
			Status                        string `json:"Status"`
		} `json:"BlueGreenDeployments"`
	}
	if err := call(options, DeploymentFile, &deployments,
		"rds", "describe-blue-green-deployments", "--filters", "Name=source,Values="+sourceARN); err != nil {
		return nil, err
	}
	if len(deployments.BlueGreenDeployments) == 0 {
		return nil, fmt.Errorf("Blue/Green Deployment not found for %s\n"+
			"Step 3（build_green.sh）が未実行か、config の actions.build が pending の可能性がある。",
			options.SourceInstanceID)
	}
	deployment := deployments.BlueGreenDeployments[0]
	if deployment.Status != "AVAILABLE" {
		return nil, fmt.Errorf("Deployment is not AVAILABLE: %s", deployment.Status)
	}

	// Green の識別子は Target ARN の末尾（...:db:<id>）である。
	greenID := deployment.Target
	if index := strings.LastIndex(greenID, ":db:"); index >= 0 {
		greenID = greenID[index+len(":db:"):]
	}
	if greenID == "" {
		return nil, fmt.Errorf("Deployment %s の Target から Green の識別子を取れない: %q",
			deployment.BlueGreenDeploymentIdentifier, deployment.Target)
	}

	// [読み取り] Green の状態。エンジン・クラス・パラメータグループの関連付けは
	// 判定器がこのファイルから読んで突き合わせる。
	var green struct {
		DBInstances []struct {
			Endpoint struct {
				Address string `json:"Address"`
			} `json:"Endpoint"`
		} `json:"DBInstances"`
	}
	if err := call(options, GreenInstanceFile, &green,
		"rds", "describe-db-instances", "--db-instance-identifier", greenID); err != nil {
		return nil, err
	}
	endpoint := ""
	if len(green.DBInstances) > 0 {
		endpoint = green.DBInstances[0].Endpoint.Address
	}

	// [読み取り] Green に反映されたパラメータ（Source=user / system / 全件）。
	// 判定器が Step 2 の CloudFormation YAML と Source=user を突き合わせる。
	for _, fetch := range []struct {
		file   string
		source []string
	}{
		{UserParametersFile, []string{"--source", "user"}},
		{SystemParametersFile, []string{"--source", "system"}},
		{AllParametersFile, nil},
	} {
		arguments := append([]string{"rds", "describe-db-parameters",
			"--db-parameter-group-name", options.TargetParameterGroup}, fetch.source...)
		if err := call(options, fetch.file, nil, arguments...); err != nil {
			return nil, err
		}
	}

	// [読み取り] レプリカ遅延。判定（0 秒であること）は判定器が行う。
	end := options.Now().UTC()
	start := end.Add(-options.ReplicaLagWindow)
	if err := call(options, ReplicaLagFile, nil,
		"cloudwatch", "get-metric-statistics",
		"--namespace", "AWS/RDS", "--metric-name", "ReplicaLag",
		"--dimensions", "Name=DBInstanceIdentifier,Value="+greenID,
		"--statistics", "Maximum", "--period", "60",
		"--start-time", start.Format(time.RFC3339),
		"--end-time", end.Format(time.RFC3339)); err != nil {
		return nil, err
	}

	return &Result{
		DeploymentID:    deployment.BlueGreenDeploymentIdentifier,
		GreenInstanceID: greenID,
		GreenEndpoint:   endpoint,
	}, nil
}

// call は AWS CLI を 1 回呼び、応答 JSON を file へ保存する。
// destination が nil でなければ解析結果も返す。**保存するのは生の応答である。**
func call(options Options, file string, destination any, arguments ...string) error {
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
			return fmt.Errorf("aws %s failed: %w: %s", called, err, strings.TrimSpace(stderr.String()))
		}
		return fmt.Errorf("aws %s failed: %w", called, err)
	}
	path := filepath.Join(options.OutputDir, file)
	if err := os.WriteFile(path, stdout.Bytes(), 0o644); err != nil {
		return fmt.Errorf("%s: 書き込めない: %w", path, err)
	}
	if destination != nil {
		if err := json.Unmarshal(stdout.Bytes(), destination); err != nil {
			return fmt.Errorf("aws %s の応答を解析できない: %w", strings.Join(arguments, " "), err)
		}
	}
	return nil
}
