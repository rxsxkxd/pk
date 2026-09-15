package generate

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"rds-mysql-upgrade/tools/internal/common"
)

// testInventory は blue と audit の 2 インスタンスを持つ最小のインベントリである。
func testInventory(t *testing.T) *common.Inventory {
	t.Helper()
	const content = `{
  "aws_region": "ap-northeast-1",
  "DBInstances": [
    {"DBInstanceIdentifier": "blue", "Engine": "mysql", "EngineVersion": "8.0.43",
     "DBInstanceClass": "db.t4g.small",
     "DBParameterGroups": [{"DBParameterGroupName": "blue-v1"}]},
    {"DBInstanceIdentifier": "audit", "Engine": "mysql", "EngineVersion": "8.0.46",
     "DBInstanceClass": "db.r6g.large",
     "DBParameterGroups": [{"DBParameterGroupName": "audit-v1"}]},
    {"DBInstanceIdentifier": "postgres", "Engine": "postgres", "EngineVersion": "16.4",
     "DBInstanceClass": "db.t4g.small",
     "DBParameterGroups": [{"DBParameterGroupName": "pg-v1"}]}
  ],
  "ParameterGroups": {
    "blue-v1": {"Parameters": {"time_zone": {"Value": "UTC", "Source": "engine-default"}}},
    "audit-v1": {"Parameters": {"time_zone": {"Value": "Asia/Tokyo", "Source": "user"}}},
    "pg-v1": {"Parameters": {}}
  }
}`
	var inventory common.Inventory
	if err := json.Unmarshal([]byte(content), &inventory); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	return &inventory
}

// catalogFrom は YAML 断片からカタログを組む。テストの意図を YAML で読めるようにする。
func catalogFrom(t *testing.T, content string) *Catalog {
	t.Helper()
	var catalog Catalog
	if err := yaml.Unmarshal([]byte(content), &catalog); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	return &catalog
}

const baseCatalog = `
database_environments: [development, staging, production]
parameter_groups:
  blue-mysql84-v1:
    template_path: generated/blue.yaml
  audit-mysql84-v1:
    template_path: generated/audit.yaml
applications:
  order:
    connections:
      primary:
        environments:
          staging:
            rds_instance: blue
            schema_name: order_staging
            target:
              db_parameter_group_name: blue-mysql84-v1
`

func TestGenerateFillsOmittedTarget(t *testing.T) {
	document, err := Generate(catalogFrom(t, baseCatalog), testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	service := document.Services["blue"]
	if service == nil {
		t.Fatal("services must be keyed by the RDS instance identifier")
	}
	// engine_version 省略時は共通ターゲットへ上げる。Blue を踏襲したら移行にならない。
	if service.TargetEngineVersion != DefaultTargetEngineVersion {
		t.Errorf("target_engine_version = %q, want %q",
			service.TargetEngineVersion, DefaultTargetEngineVersion)
	}
	// db_instance_class 省略時は Blue の実値を踏襲する。
	if service.TargetDBInstanceClass != "db.t4g.small" {
		t.Errorf("target_db_instance_class = %q", service.TargetDBInstanceClass)
	}
	// 自動マイナーバージョンアップグレードの差分を判定へ持ち込まない。
	if service.SourceEngineVersion != "8.0" {
		t.Errorf("source_engine_version = %q, want 8.0", service.SourceEngineVersion)
	}
	// 確認用のパラメータ実値は収集値をそのまま載せる。パラメータ名がキーになる。
	want := SourceParameter{Value: "UTC", Source: "engine-default"}
	if got := service.SourceDBParameters["time_zone"]; got != want {
		t.Errorf("source_db_parameters[time_zone] = %+v, want %+v", got, want)
	}
	if len(service.SourceDBParameters) != 1 {
		t.Errorf("source_db_parameters = %+v, want only the collected parameters",
			service.SourceDBParameters)
	}
	// 承認は常に pending で生成する。
	if service.Actions.Build != "pending" || service.Actions.Switchover != "pending" ||
		service.Actions.Cleanup != "pending" {
		t.Errorf("actions = %+v, want all pending", service.Actions)
	}
	if service.MySQLVerification.AuthMethod != GeneratedMySQLAuthMethod {
		t.Errorf("auth_method = %q", service.MySQLVerification.AuthMethod)
	}
}

func TestGenerateKeepsExplicitTarget(t *testing.T) {
	catalog := catalogFrom(t, strings.Replace(baseCatalog,
		"              db_parameter_group_name: blue-mysql84-v1",
		"              db_parameter_group_name: blue-mysql84-v1\n"+
			"              engine_version: \"8.4.10\"\n"+
			"              db_instance_class: db.r6g.xlarge", 1))
	document, err := Generate(catalog, testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	service := document.Services["blue"]
	if service.TargetEngineVersion != "8.4.10" {
		t.Errorf("target_engine_version = %q", service.TargetEngineVersion)
	}
	if service.TargetDBInstanceClass != "db.r6g.xlarge" {
		t.Errorf("target_db_instance_class = %q", service.TargetDBInstanceClass)
	}
}

func TestGenerateMergesConnectionsOnOneInstance(t *testing.T) {
	catalog := catalogFrom(t, baseCatalog+`
      reporting:
        environments:
          staging:
            rds_instance: blue
            schema_name: order_reporting
            target:
              db_parameter_group_name: blue-mysql84-v1
`)
	document, err := Generate(catalog, testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if len(document.Services) != 1 {
		t.Fatalf("services = %d, want 1 deployment for the shared instance", len(document.Services))
	}
	got := strings.Join(document.Services["blue"].Schemas, ",")
	if got != "order_reporting,order_staging" {
		t.Errorf("schemas = %q, want them aggregated and sorted", got)
	}
}

func TestGenerateRejectsConflictingConnectionsOnOneInstance(t *testing.T) {
	// 同じインスタンスを指すのに target が食い違う。どちらが正か決められない。
	catalog := catalogFrom(t, baseCatalog+`
      reporting:
        environments:
          staging:
            rds_instance: blue
            schema_name: order_reporting
            target:
              db_parameter_group_name: blue-mysql84-v1
              db_instance_class: db.r6g.xlarge
`)
	_, err := Generate(catalog, testInventory(t), "staging")
	if err == nil {
		t.Fatal("Generate succeeded, want failure")
	}
	if !strings.Contains(err.Error(), "target_db_instance_class が食い違う") {
		t.Errorf("error = %v", err)
	}
}

func TestGenerateRejectsBadInput(t *testing.T) {
	cases := []struct {
		name    string
		catalog string
		want    string
	}{
		{
			name:    "接続が 1 つも無い環境",
			catalog: baseCatalog,
			want:    "no connection is defined for the environment",
		},
		{
			name: "binding のキー誤字",
			catalog: strings.Replace(baseCatalog,
				"            schema_name: order_staging",
				"            schema_name: order_staging\n            schema_nmae: typo", 1),
			want: "has unknown keys: schema_nmae",
		},
		{
			name: "target のキー誤字",
			catalog: strings.Replace(baseCatalog,
				"              db_parameter_group_name: blue-mysql84-v1",
				"              db_parameter_group_name: blue-mysql84-v1\n              engine_ver: \"8.4\"", 1),
			want: "target has unknown keys: engine_ver",
		},
		{
			name: "target 自体が無い",
			catalog: strings.Replace(baseCatalog,
				"            target:\n              db_parameter_group_name: blue-mysql84-v1", "", 1),
			want: "db_parameter_group_name is required",
		},
		{
			name: "カタログに無いパラメータグループを指す",
			catalog: strings.Replace(baseCatalog,
				"db_parameter_group_name: blue-mysql84-v1", "db_parameter_group_name: absent-v1", 1),
			want: "catalog.parameter_groups に無い",
		},
		{
			name: "インベントリに無いインスタンスを指す",
			catalog: strings.Replace(baseCatalog,
				"            rds_instance: blue", "            rds_instance: absent", 1),
			want: "absent from inventory",
		},
		{
			name: "MySQL 以外のエンジン",
			catalog: strings.Replace(baseCatalog,
				"            rds_instance: blue", "            rds_instance: postgres", 1),
			want: "Engine must be mysql",
		},
		{
			name: "schema_name が無い",
			catalog: strings.Replace(baseCatalog,
				"            schema_name: order_staging", "", 1),
			want: "schema_name is required",
		},
		{
			name: "database_environments に無い環境を書いている",
			catalog: strings.Replace(baseCatalog,
				"          staging:", "          stagng:", 1),
			want: "catalog.database_environments に無い環境である",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			environment := "staging"
			if testCase.name == "接続が 1 つも無い環境" {
				environment = "development"
			}
			_, err := Generate(catalogFrom(t, testCase.catalog), testInventory(t), environment)
			if err == nil {
				t.Fatal("Generate succeeded, want failure")
			}
			if !strings.Contains(err.Error(), testCase.want) {
				t.Errorf("error = %v, want it to contain %q", err, testCase.want)
			}
		})
	}
}

func TestGenerateRejectsUnknownEnvironmentArgument(t *testing.T) {
	_, err := Generate(catalogFrom(t, baseCatalog), testInventory(t), "qa")
	if err == nil || !strings.Contains(err.Error(), "unknown environment: qa") {
		t.Errorf("error = %v", err)
	}
}

func TestWriteProducesTwoSpaceIndentedYAML(t *testing.T) {
	document, err := Generate(catalogFrom(t, baseCatalog), testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	path := filepath.Join(t.TempDir(), "staging.deployment.yml")
	if err := Write(path, document); err != nil {
		t.Fatalf("Write: %v", err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	text := string(content)
	// 出力のキー順は構造体のフィールド順で決まる。既存の deployment.yml に揃える。
	for _, want := range []string{
		"environment: staging\n",
		"aws_region: ap-northeast-1\n",
		"services:\n  blue:\n    source_db_instance_identifier: blue\n",
		"    source_engine_version: \"8.0\"\n",
		"    source_db_parameters:\n      time_zone:\n        value: UTC\n        source: engine-default\n",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("output does not contain %q\n---\n%s", want, text)
		}
	}
	// user はカタログに書けないため、生成結果にも現れない。
	if strings.Contains(text, "user:") {
		t.Errorf("generated config must not carry a user key\n%s", text)
	}
}
