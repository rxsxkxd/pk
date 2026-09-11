package report

import (
	"encoding/json"
	"fmt"
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
    "shared-v1": {"Parameters": {"time_zone": {"Value": "Asia/Tokyo", "Source": "user"}}},
    "solo-v1": {"Parameters": {"time_zone": {"Value": "UTC", "Source": "engine-default"}}}
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

// writeTemplate は Step 2 の生成物を模した CloudFormation テンプレートを置き、パスを返す。
// parameters には Parameters 配下の行をそのまま渡す。
func writeTemplate(t *testing.T, name, parameters string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name+".yaml")
	content := fmt.Sprintf(`Resources:
  DBParameterGroup:
    Type: AWS::RDS::DBParameterGroup
    Properties:
      Family: mysql8.4
      Parameters:
%s`, parameters)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return path
}

// withTemplates はカタログ中の template_path を、実際に置いたテンプレートへ差し替える。
func withTemplates(t *testing.T, catalog, sharedParameters, soloParameters string) string {
	t.Helper()
	catalog = strings.Replace(catalog, "generated/shared.yaml",
		writeTemplate(t, "shared", sharedParameters), 1)
	return strings.Replace(catalog, "generated/solo.yaml",
		writeTemplate(t, "solo", soloParameters), 1)
}

func buildReport(t *testing.T, catalog string) *Report {
	t.Helper()
	// 既定では、shared は現状（Asia/Tokyo）と食い違う UTC を、solo は一致する UTC を宣言する。
	document, err := Build(
		catalogFrom(t, withTemplates(t, catalog, "        time_zone: UTC", "        time_zone: UTC")),
		testInventory(t), "staging")
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
		"## パラメータの現状と適用予定値",
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
		// 現状と適用予定値が食い違えば、意図した変更かを問う。
		"`time_zone` が切替で `Asia/Tokyo` から `UTC` へ変わる。意図した変更かを確認する",
		// time_zone には datetime 列への影響の参照先を添える。
		"reference/mysql-timezone-problem-summary.md",
		// 承認は人が書く。
		"`actions` は生成時点ですべて `pending` である",
		// 判定しない範囲を明示する。
		"自動判定していない。人がレビューする",
	} {
		if !strings.Contains(markdown, want) {
			t.Errorf("review points do not contain %q\n%s", want, markdown)
		}
	}
	// 一致しているインスタンスは確認事項を出さない。
	if strings.Contains(markdown, "`solo` の `time_zone` が切替で") {
		t.Errorf("a matching parameter must not raise a point\n%s", markdown)
	}
}

// 現状と適用予定値の突き合わせが、判定ごとに正しく出ることを確かめる。
func TestComparisonVerdicts(t *testing.T) {
	cases := []struct {
		name        string
		declared    string
		wantVerdict string
		wantPlanned string
		wantPoint   string
	}{
		{
			name:        "一致",
			declared:    "        time_zone: Asia/Tokyo",
			wantVerdict: VerdictSame,
			wantPlanned: "Asia/Tokyo",
		},
		{
			name:        "差異",
			declared:    "        time_zone: UTC",
			wantVerdict: VerdictDifferent,
			wantPlanned: "UTC",
			wantPoint:   "`time_zone` が切替で `Asia/Tokyo` から `UTC` へ変わる",
		},
		{
			// 組み込み関数は CloudFormation のパラメータ解決なしには実値が決まらない。
			name:        "組み込み関数",
			declared:    "        time_zone: !Ref TimeZone",
			wantVerdict: VerdictIntrinsic,
			wantPlanned: "Ref",
			wantPoint:   "組み込み関数（Ref）になっており、実値が決まらない",
		},
		{
			// テンプレートが宣言していなければ 8.4 のエンジン既定値になる。
			name:        "テンプレート未宣言",
			declared:    "        character_set_server: utf8mb4",
			wantVerdict: VerdictNotDeclared,
			wantPlanned: "—",
			wantPoint:   "移行先テンプレートで宣言されていない",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			catalog := withTemplates(t, sharedCatalog, testCase.declared, "        time_zone: UTC")
			document, err := Build(catalogFrom(t, catalog), testInventory(t), "staging")
			if err != nil {
				t.Fatalf("Build: %v", err)
			}
			comparisons := document.Deployments[0].Comparisons()
			if len(comparisons) != 1 {
				t.Fatalf("comparisons = %+v, want one per collected parameter", comparisons)
			}
			got := comparisons[0]
			if got.Name != "time_zone" || got.Current != "Asia/Tokyo" || got.CurrentSource != "user" {
				t.Errorf("comparison = %+v", got)
			}
			if got.Verdict != testCase.wantVerdict || got.Planned != testCase.wantPlanned {
				t.Errorf("verdict = %q planned = %q, want %q / %q",
					got.Verdict, got.Planned, testCase.wantVerdict, testCase.wantPlanned)
			}
			if testCase.wantPoint != "" && !strings.Contains(document.Markdown(), testCase.wantPoint) {
				t.Errorf("review points do not contain %q\n%s", testCase.wantPoint, document.Markdown())
			}
		})
	}
}

// テンプレートは Step 2 の成果物である。まだ無い段階でもレポートは出す。
func TestBuildToleratesMissingTemplate(t *testing.T) {
	document, err := Build(catalogFrom(t, sharedCatalog), testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	deployment := document.Deployments[0]
	if deployment.TargetParameterGroup != nil {
		t.Error("TargetParameterGroup must be nil when the template cannot be read")
	}
	if deployment.TargetParameterGroupError == "" {
		t.Error("TargetParameterGroupError must carry the reason")
	}
	comparisons := deployment.Comparisons()
	if len(comparisons) != 1 || comparisons[0].Verdict != VerdictNoTemplate {
		t.Errorf("comparisons = %+v", comparisons)
	}
	markdown := document.Markdown()
	if !strings.Contains(markdown, "**読み込めなかった**") {
		t.Errorf("markdown does not report the unreadable template\n%s", markdown)
	}
	if !strings.Contains(markdown, "Step 2 を実施済みか、パスが正しいかを確認する") {
		t.Errorf("review points do not mention the unreadable template\n%s", markdown)
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
