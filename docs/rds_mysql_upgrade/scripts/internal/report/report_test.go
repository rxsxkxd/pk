package report

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"rds-mysql-upgrade/scripts/internal/common"
	"rds-mysql-upgrade/scripts/internal/generate"
)

func testInventory(t *testing.T) *common.Inventory {
	t.Helper()
	const content = `{
  "aws_region": "ap-northeast-1",
  "DBInstances": [
    {"DBInstanceIdentifier": "shared", "Engine": "mysql", "EngineVersion": "8.0.43",
     "DBInstanceClass": "db.r6g.large",
     "DBParameterGroups": [{"DBParameterGroupName": "shared-v1"}]},
    {"DBInstanceIdentifier": "solo", "Engine": "mysql", "EngineVersion": "8.0.46",
     "DBInstanceClass": "db.t4g.small",
     "DBParameterGroups": [{"DBParameterGroupName": "solo-v1"}]}
  ],
  "ParameterGroups": {
    "shared-v1": {"TimeZone": "Asia/Tokyo", "TimeZoneSource": "user"},
    "solo-v1": {"TimeZone": "UTC", "TimeZoneSource": "engine-default"}
  }
}`
	var inventory common.Inventory
	if err := json.Unmarshal([]byte(content), &inventory); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	return &inventory
}

func catalogFrom(t *testing.T, content string) *generate.Catalog {
	t.Helper()
	var catalog generate.Catalog
	if err := yaml.Unmarshal([]byte(content), &catalog); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	return &catalog
}

// 2 アプリが 1 インスタンスへ同居し、もう 1 つは単独。time_zone は user と
// engine-default の両方を含む。要確認事項の分岐を通すための構成である。
const sharedCatalog = `
database_environments: [staging]
parameter_groups:
  shared-mysql84-v1:
    template_path: generated/shared.yaml
  solo-mysql84-v1:
    template_path: generated/solo.yaml
mysql_verification:
  enabled: true
  parameter_name: /rds-bg/mysql-password
  user_parameter_name: /rds-bg/mysql-user
applications:
  order:
    connections:
      primary:
        environments:
          staging:
            rds_instance: shared
            schema_name: order_staging
            target:
              db_parameter_group_name: shared-mysql84-v1
      reporting:
        environments:
          staging:
            rds_instance: solo
            schema_name: order_reporting
            target:
              db_parameter_group_name: solo-mysql84-v1
  batch:
    connections:
      primary:
        environments:
          staging:
            rds_instance: shared
            schema_name: batch_staging
            target:
              db_parameter_group_name: shared-mysql84-v1
`

func buildReport(t *testing.T, catalog string) *Report {
	t.Helper()
	document, err := Build(catalogFrom(t, catalog), testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	return document
}

func TestBuildGroupsConnectionsByInstance(t *testing.T) {
	document := buildReport(t, sharedCatalog)
	if document.Environment != "staging" || document.AwsRegion != "ap-northeast-1" {
		t.Errorf("document = %+v", document)
	}
	// Deployments は RDS インスタンス識別子の昇順である。
	if len(document.Deployments) != 2 {
		t.Fatalf("deployments = %d, want 2", len(document.Deployments))
	}
	if document.Deployments[0].Service.SourceDBInstanceIdentifier != "shared" {
		t.Errorf("deployments must be sorted by instance identifier: %s",
			document.Deployments[0].Service.SourceDBInstanceIdentifier)
	}

	// 生成結果にはアプリ名が残らないため、レポートで接続元を補う。
	var origins []string
	for _, ref := range document.Deployments[0].Connections {
		origins = append(origins, ref.Application+"."+ref.Connection)
	}
	if strings.Join(origins, ",") != "batch.primary,order.primary" {
		t.Errorf("connections = %v, want both applications in name order", origins)
	}
}

func TestMarkdownContainsEverySection(t *testing.T) {
	markdown := buildReport(t, sharedCatalog).Markdown()
	for _, want := range []string{
		"# Blue/Green 移行設定レビュー: staging",
		"## 移行元と移行先",
		"## 影響範囲（スキーマと接続元）",
		"## time_zone の実値",
		"## Step 4 の MySQL 接続検証",
		"## 要確認事項",
	} {
		if !strings.Contains(markdown, want) {
			t.Errorf("markdown does not contain %q", want)
		}
	}
	// 同居インスタンスの接続元とスキーマが並ぶ。
	if !strings.Contains(markdown, "`batch.primary`, `order.primary`") {
		t.Errorf("markdown does not list the co-located connections\n%s", markdown)
	}
	if !strings.Contains(markdown, "`batch_staging`, `order_staging`") {
		t.Errorf("markdown does not list the aggregated schemas\n%s", markdown)
	}
}

func TestMarkdownRaisesReviewPoints(t *testing.T) {
	markdown := buildReport(t, sharedCatalog).Markdown()
	for _, want := range []string{
		// 同居は切替の停止影響が複数アプリへ及ぶ。
		"は 2 アプリが同居している（batch, order）",
		// インスタンス単位でしか切り替えられない。
		"は 2 スキーマを収容している",
		// time_zone を明示設定していれば 8.4 側との一致が論点になる。
		"time_zone を `Asia/Tokyo` に明示設定している（由来: user）",
		// 承認は人が書く。
		"`actions` は生成時点ですべて `pending` である",
		// 判定しない範囲を明示する。
		"自動判定していない。人がレビューする",
	} {
		if !strings.Contains(markdown, want) {
			t.Errorf("review points do not contain %q\n%s", want, markdown)
		}
	}
	// engine-default のインスタンスは time_zone の確認事項を出さない。
	if strings.Contains(markdown, "`solo` は time_zone を") {
		t.Errorf("engine-default must not raise a time_zone point\n%s", markdown)
	}
}

func TestMarkdownWarnsOnSharedTargetParameterGroup(t *testing.T) {
	// 2 インスタンスが同じ移行先パラメータグループを共有している。
	catalog := strings.Replace(sharedCatalog,
		"              db_parameter_group_name: solo-mysql84-v1",
		"              db_parameter_group_name: shared-mysql84-v1", 1)
	markdown := buildReport(t, catalog).Markdown()
	if !strings.Contains(markdown, "を 2 インスタンスが共有している（shared, solo）") {
		t.Errorf("shared parameter group is not reported\n%s", markdown)
	}
}

func TestMarkdownReportsDisabledVerification(t *testing.T) {
	catalog := strings.Replace(sharedCatalog, `mysql_verification:
  enabled: true
  parameter_name: /rds-bg/mysql-password
  user_parameter_name: /rds-bg/mysql-user
`, "", 1)
	markdown := buildReport(t, catalog).Markdown()
	if !strings.Contains(markdown, "mysql_verification が無効である") {
		t.Errorf("disabled verification is not reported\n%s", markdown)
	}
	// 無効なら SSM パラメータ名の欄は埋めない。
	if strings.Contains(markdown, "/rds-bg/mysql-password") {
		t.Errorf("parameter names must not appear when verification is disabled\n%s", markdown)
	}
}

// パスワードやユーザー名そのものは、どの経路でもレポートへ出てこない。
func TestMarkdownNeverCarriesCredentials(t *testing.T) {
	markdown := buildReport(t, sharedCatalog).Markdown()
	for _, forbidden := range []string{"password:", "user:", "auth_method"} {
		if strings.Contains(markdown, forbidden) {
			t.Errorf("markdown must not carry %q\n%s", forbidden, markdown)
		}
	}
	// パラメータ名（在り処）は載せる。値ではない。
	if !strings.Contains(markdown, "`/rds-bg/mysql-password`") {
		t.Errorf("markdown should carry the SSM parameter name\n%s", markdown)
	}
}

func TestBuildPropagatesGenerateFailure(t *testing.T) {
	// 判定の重複を避けるため generate を再利用している。入力の誤りはそのまま伝わる。
	catalog := strings.Replace(sharedCatalog, "            rds_instance: shared",
		"            rds_instance: absent", 1)
	if _, err := Build(catalogFrom(t, catalog), testInventory(t), "staging"); err == nil {
		t.Fatal("Build succeeded, want failure")
	}
}

func TestWriteProducesReadableMarkdown(t *testing.T) {
	path := filepath.Join(t.TempDir(), "report.md")
	if err := Write(path, buildReport(t, sharedCatalog)); err != nil {
		t.Fatalf("Write: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o644 {
		t.Errorf("permission = %04o, want 0644", got)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if !strings.HasPrefix(string(content), "# Blue/Green 移行設定レビュー: staging\n") {
		t.Errorf("unexpected head: %q", string(content)[:60])
	}
}
