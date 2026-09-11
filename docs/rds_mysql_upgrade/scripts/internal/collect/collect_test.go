package collect

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// fakeAWS は PATH 上の aws を差し替える。収集は AWS CLI を exec するだけなので、
// これで実 AWS に触れずに引数の組み立てと応答の扱いを確かめられる。
// 呼び出した引数は 1 行ずつ recordPath へ追記される。
func fakeAWS(t *testing.T, script string) (recordPath string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("POSIX シェルのダミーを使うため Windows では実行しない")
	}
	directory := t.TempDir()
	recordPath = filepath.Join(directory, "calls.txt")
	body := "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$*\" >> \"" +
		recordPath + "\"\n" + script
	path := filepath.Join(directory, "aws")
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	return recordPath
}

func calls(t *testing.T, recordPath string) []string {
	t.Helper()
	content, err := os.ReadFile(recordPath)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	var recorded []string
	for _, line := range strings.Split(strings.TrimSpace(string(content)), "\n") {
		if line != "" {
			recorded = append(recorded, line)
		}
	}
	return recorded
}

const twoInstancesSharingOneGroup = `
case " $* " in
  *' describe-db-instances '*)
    cat <<'JSON'
{"DBInstances": [
  {"DBInstanceIdentifier": "blue", "Engine": "mysql", "EngineVersion": "8.0.43",
   "DBInstanceClass": "db.t4g.small",
   "DBParameterGroups": [{"DBParameterGroupName": "shared-v1"}]},
  {"DBInstanceIdentifier": "green", "Engine": "mysql", "EngineVersion": "8.0.43",
   "DBInstanceClass": "db.t4g.small",
   "DBParameterGroups": [{"DBParameterGroupName": "shared-v1"}]}
]}
JSON
    ;;
  *' describe-db-parameters '*)
    cat <<'JSON'
{"Parameters": [
  {"ParameterName": "binlog_format", "ParameterValue": "ROW", "Source": "user"},
  {"ParameterName": "time_zone", "ParameterValue": "Asia/Tokyo", "Source": "user"}
]}
JSON
    ;;
  *) echo "unexpected AWS CLI call: $*" >&2; exit 64 ;;
esac
`

func TestInventoryCallsOnlyReadOnlyAPIs(t *testing.T) {
	recordPath := fakeAWS(t, twoInstancesSharingOneGroup)

	inventory, err := Inventory(Options{Region: "ap-northeast-1", Profile: "readonly"})
	if err != nil {
		t.Fatalf("Inventory: %v", err)
	}

	recorded := calls(t, recordPath)
	want := []string{
		"--region ap-northeast-1 --profile readonly rds describe-db-instances --output json",
		"--region ap-northeast-1 --profile readonly rds describe-db-parameters" +
			" --db-parameter-group-name shared-v1 --output json",
	}
	sort.Strings(recorded)
	sort.Strings(want)
	if strings.Join(recorded, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls =\n%s\nwant\n%s", strings.Join(recorded, "\n"), strings.Join(want, "\n"))
	}
	// 同じパラメータグループを共有していても API 呼び出しは 1 回で済ませる。
	if len(recorded) != 2 {
		t.Errorf("calls = %d, want 2 (one describe per unique parameter group)", len(recorded))
	}

	if inventory.AwsRegion != "ap-northeast-1" {
		t.Errorf("aws_region = %q", inventory.AwsRegion)
	}
	if len(inventory.DBInstances) != 2 {
		t.Errorf("DBInstances = %d, want 2", len(inventory.DBInstances))
	}
	facts := inventory.ParameterGroups["shared-v1"]
	if facts == nil || facts.TimeZone != "Asia/Tokyo" || facts.TimeZoneSource != "user" {
		t.Errorf("ParameterGroups = %+v", inventory.ParameterGroups)
	}
}

func TestInventoryOmitsProfileWhenEmpty(t *testing.T) {
	recordPath := fakeAWS(t, twoInstancesSharingOneGroup)
	if _, err := Inventory(Options{Region: "ap-northeast-1"}); err != nil {
		t.Fatalf("Inventory: %v", err)
	}
	for _, call := range calls(t, recordPath) {
		if strings.Contains(call, "--profile") {
			t.Errorf("call must not carry --profile when none is given: %s", call)
		}
	}
}

func TestInventoryTreatsMissingTimeZoneAsEmpty(t *testing.T) {
	// time_zone が応答に無い場合も収集側では判定しない。空で通し、必要なら生成側が落とす。
	fakeAWS(t, strings.Replace(twoInstancesSharingOneGroup,
		`  {"ParameterName": "time_zone", "ParameterValue": "Asia/Tokyo", "Source": "user"}`,
		`  {"ParameterName": "max_connections", "ParameterValue": "100", "Source": "system"}`, 1))

	inventory, err := Inventory(Options{Region: "ap-northeast-1"})
	if err != nil {
		t.Fatalf("Inventory: %v", err)
	}
	facts := inventory.ParameterGroups["shared-v1"]
	if facts == nil || facts.TimeZone != "" || facts.TimeZoneSource != "" {
		t.Errorf("ParameterGroups[shared-v1] = %+v, want empty facts", facts)
	}
}

func TestInventoryPropagatesAWSFailure(t *testing.T) {
	fakeAWS(t, "echo 'An error occurred (AccessDenied)' >&2\nexit 255\n")
	_, err := Inventory(Options{Region: "ap-northeast-1"})
	if err == nil {
		t.Fatal("Inventory succeeded, want failure")
	}
	// 原因を追えるよう AWS CLI の stderr をそのまま伝える。
	if !strings.Contains(err.Error(), "AccessDenied") {
		t.Errorf("error = %v, want it to carry the AWS CLI stderr", err)
	}
}

func TestInventoryRejectsResponseWithoutDBInstances(t *testing.T) {
	fakeAWS(t, "echo '{}'\n")
	_, err := Inventory(Options{Region: "ap-northeast-1"})
	if err == nil || !strings.Contains(err.Error(), "has no DBInstances array") {
		t.Errorf("error = %v", err)
	}
}

func TestInventoryAcceptsEmptyDBInstances(t *testing.T) {
	// 対象なしは異常ではない。キー自体が無い応答だけを落とす。
	fakeAWS(t, "echo '{\"DBInstances\": []}'\n")
	inventory, err := Inventory(Options{Region: "ap-northeast-1"})
	if err != nil {
		t.Fatalf("Inventory: %v", err)
	}
	if len(inventory.DBInstances) != 0 || inventory.ParameterGroups == nil {
		t.Errorf("inventory = %+v, want empty instances and a non-nil ParameterGroups", inventory)
	}
}
