package greenstate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeAWS は PATH 上の aws を差し替える。収集は AWS CLI を exec するだけなので、
// 呼び出し引数の記録と固定応答で振る舞いを確かめられる。
func fakeAWS(t *testing.T, script string) (recordPath string) {
	t.Helper()
	directory := t.TempDir()
	recordPath = filepath.Join(directory, "calls.log")
	body := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + recordPath + "\n" + script
	if err := os.WriteFile(filepath.Join(directory, "aws"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	return recordPath
}

// 移行元・Deployment（AVAILABLE）・Green を返す標準的な応答。
const available = `
case "$*" in
  *"describe-db-instances --db-instance-identifier blue"*)
    echo '{"DBInstances":[{"DBInstanceArn":"arn:aws:rds:ap-northeast-1:1:db:blue"}]}' ;;
  *describe-blue-green-deployments*)
    echo '{"BlueGreenDeployments":[{"BlueGreenDeploymentIdentifier":"bgd-1","Target":"arn:aws:rds:ap-northeast-1:1:db:green-1","Status":"AVAILABLE"}]}' ;;
  *"describe-db-instances --db-instance-identifier green-1"*)
    echo '{"DBInstances":[{"Endpoint":{"Address":"green-1.example.rds.amazonaws.com"}}]}' ;;
  *describe-db-parameters*) echo '{"Parameters":[]}' ;;
  *get-metric-statistics*) echo '{"Datapoints":[{"Maximum":0}]}' ;;
  *) echo '{}' ;;
esac
`

func options(t *testing.T) Options {
	t.Helper()
	return Options{
		Region:               "ap-northeast-1",
		SourceInstanceID:     "blue",
		TargetParameterGroup: "pg-84",
		OutputDir:            t.TempDir(),
		Now:                  func() time.Time { return time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC) },
	}
}

func TestCollectWritesAllFilesAndReturnsIdentifiers(t *testing.T) {
	record := fakeAWS(t, available)
	opts := options(t)

	result, err := Collect(opts)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if result.DeploymentID != "bgd-1" || result.GreenInstanceID != "green-1" ||
		result.GreenEndpoint != "green-1.example.rds.amazonaws.com" {
		t.Fatalf("unexpected result: %+v", result)
	}

	// 判定器の --input-dir が読むファイルがすべて揃っていること。
	for _, name := range []string{SourceInstanceFile, DeploymentFile, GreenInstanceFile,
		UserParametersFile, SystemParametersFile, AllParametersFile, ReplicaLagFile} {
		if _, err := os.Stat(filepath.Join(opts.OutputDir, name)); err != nil {
			t.Errorf("%s が書き出されていない: %v", name, err)
		}
	}

	calls, _ := os.ReadFile(record)
	log := string(calls)
	// Deployment は source の ARN で引き当てる（ID を設定ファイルに持たない）。
	if !strings.Contains(log, "--filters Name=source,Values=arn:aws:rds:ap-northeast-1:1:db:blue") {
		t.Errorf("source ARN で引き当てていない:\n%s", log)
	}
	// パラメータは 3 種類取る。
	for _, want := range []string{"--source user", "--source system"} {
		if !strings.Contains(log, want) {
			t.Errorf("%s の取得が無い:\n%s", want, log)
		}
	}
	// レプリカ遅延は Green に対して、直近 10 分を見る。
	if !strings.Contains(log, "Value=green-1") ||
		!strings.Contains(log, "--start-time 2026-09-24T11:50:00Z --end-time 2026-09-24T12:00:00Z") {
		t.Errorf("レプリカ遅延の取得範囲が違う:\n%s", log)
	}
	// **同じ API を二重に叩かない**（シェル版は JSON 保存と --query で 2 回呼んでいた）。
	if strings.Count(log, "describe-blue-green-deployments") != 1 {
		t.Errorf("describe-blue-green-deployments を 1 回だけ呼ぶこと:\n%s", log)
	}
	if strings.Contains(log, "--query") {
		t.Errorf("--query を使わず JSON から読むこと:\n%s", log)
	}
	// 全呼び出しに --region と --output json が付く。
	for _, line := range strings.Split(strings.TrimSpace(log), "\n") {
		if !strings.HasPrefix(line, "--region ap-northeast-1 ") || !strings.HasSuffix(line, "--output json") {
			t.Errorf("--region / --output json が付いていない: %s", line)
		}
	}
}

func TestCollectPassesProfile(t *testing.T) {
	record := fakeAWS(t, available)
	opts := options(t)
	opts.Profile = "my-profile"
	if _, err := Collect(opts); err != nil {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(record)
	if strings.Count(string(calls), "--profile my-profile") != 7 {
		t.Errorf("全 7 呼び出しに --profile が付くこと:\n%s", calls)
	}
}

func TestCollectFailsWhenDeploymentMissing(t *testing.T) {
	fakeAWS(t, strings.Replace(available,
		`echo '{"BlueGreenDeployments":[{"BlueGreenDeploymentIdentifier":"bgd-1","Target":"arn:aws:rds:ap-northeast-1:1:db:green-1","Status":"AVAILABLE"}]}'`,
		`echo '{"BlueGreenDeployments":[]}'`, 1))
	_, err := Collect(options(t))
	if err == nil || !strings.Contains(err.Error(), "Blue/Green Deployment not found for blue") {
		t.Fatalf("Deployment が無いことを伝えること: %v", err)
	}
	if !strings.Contains(err.Error(), "actions.build が pending") {
		t.Errorf("原因の候補を示すこと: %v", err)
	}
}

func TestCollectFailsWhenDeploymentNotAvailable(t *testing.T) {
	fakeAWS(t, strings.Replace(available, `"Status":"AVAILABLE"`, `"Status":"PROVISIONING"`, 1))
	_, err := Collect(options(t))
	if err == nil || !strings.Contains(err.Error(), "Deployment is not AVAILABLE: PROVISIONING") {
		t.Fatalf("AVAILABLE でないことを伝えること: %v", err)
	}
}

func TestCollectPropagatesAWSFailure(t *testing.T) {
	fakeAWS(t, "echo 'An error occurred (AccessDenied)' >&2\nexit 255\n")
	_, err := Collect(options(t))
	if err == nil || !strings.Contains(err.Error(), "AccessDenied") {
		t.Fatalf("AWS CLI の失敗理由を伝えること: %v", err)
	}
}

func TestCollectFailsWhenSourceMissing(t *testing.T) {
	fakeAWS(t, `echo '{"DBInstances":[]}'`)
	_, err := Collect(options(t))
	if err == nil || !strings.Contains(err.Error(), "移行元 blue の ARN を取得できない") {
		t.Fatalf("移行元が見つからないことを伝えること: %v", err)
	}
}
