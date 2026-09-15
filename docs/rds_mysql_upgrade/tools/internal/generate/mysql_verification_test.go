package generate

import (
	"strings"
	"testing"
)

// mysql_verification はルート既定値へ接続配下の指定をキー単位で重ねる。
// 環境ごとに AWS アカウントが分かれるため、通常はルート既定値だけで足りる。
func TestResolveMySQLVerificationMergesPerKey(t *testing.T) {
	const catalog = `
database_environments: [staging]
parameter_groups:
  blue-mysql84-v1:
    template_path: generated/blue.yaml
  audit-mysql84-v1:
    template_path: generated/audit.yaml
mysql_verification:
  enabled: true
  parameter_name: /rds-bg/mysql-password
  user_parameter_name: /rds-bg/mysql-user
  port: 3306
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
      audit:
        environments:
          staging:
            rds_instance: audit
            schema_name: order_audit
            target:
              db_parameter_group_name: audit-mysql84-v1
            mysql_verification:
              parameter_name: /rds-bg/audit/mysql-password
              port: 3307
`
	document, err := Generate(catalogFrom(t, catalog), testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}

	// 接続配下に指定が無ければ、ルート既定値をそのまま使う。
	inherited := document.Services["blue"].MySQLVerification
	if inherited.ParameterName != "/rds-bg/mysql-password" || inherited.Port != 3306 {
		t.Errorf("inherited = %+v", inherited)
	}
	if !inherited.Enabled {
		t.Error("enabled must be inherited from the root default")
	}

	// 指定したキーだけ上書きし、残りはルート既定値を引き継ぐ。
	overridden := document.Services["audit"].MySQLVerification
	if overridden.ParameterName != "/rds-bg/audit/mysql-password" {
		t.Errorf("parameter_name = %q, want the per-DB override", overridden.ParameterName)
	}
	if overridden.Port != 3307 {
		t.Errorf("port = %d, want the per-DB override", overridden.Port)
	}
	if overridden.UserParameterName != "/rds-bg/mysql-user" {
		t.Errorf("user_parameter_name = %q, want it inherited from the root default",
			overridden.UserParameterName)
	}
}

func TestResolveMySQLVerificationRequiresBothParameterNames(t *testing.T) {
	// enabled のときは、パスワードとユーザー名の両方の在り処が必要である。
	base := `
database_environments: [staging]
parameter_groups:
  blue-mysql84-v1:
    template_path: generated/blue.yaml
mysql_verification:
  enabled: true
%s
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
	cases := []struct {
		name     string
		defaults string
		want     string
	}{
		{
			name:     "どちらも無い",
			defaults: "",
			want:     "mysql_verification.parameter_name が必要である",
		},
		{
			name:     "user_parameter_name だけ無い",
			defaults: "  parameter_name: /rds-bg/mysql-password",
			want:     "mysql_verification.user_parameter_name が必要である",
		},
		{
			name:     "parameter_name だけ無い",
			defaults: "  user_parameter_name: /rds-bg/mysql-user",
			want:     "mysql_verification.parameter_name が必要である",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			catalog := catalogFrom(t, strings.Replace(base, "%s", testCase.defaults, 1))
			_, err := Generate(catalog, testInventory(t), "staging")
			if err == nil {
				t.Fatal("Generate succeeded, want failure")
			}
			if !strings.Contains(err.Error(), testCase.want) {
				t.Errorf("error = %v, want it to contain %q", err, testCase.want)
			}
		})
	}
}

func TestResolveMySQLVerificationSkipsChecksWhenDisabled(t *testing.T) {
	// enabled: false なら接続しないため、パラメータ名は無くてよい。
	const catalog = `
database_environments: [staging]
parameter_groups:
  blue-mysql84-v1:
    template_path: generated/blue.yaml
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
	document, err := Generate(catalogFrom(t, catalog), testInventory(t), "staging")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	verification := document.Services["blue"].MySQLVerification
	if verification.Enabled {
		t.Error("enabled must default to false")
	}
	if verification.Port != 3306 {
		t.Errorf("port = %d, want the 3306 default", verification.Port)
	}
	if verification.AuthMethod != GeneratedMySQLAuthMethod {
		t.Errorf("auth_method = %q, want it fixed to parameter_store", verification.AuthMethod)
	}
}

// ユーザー名もパスワードも SSM 側へ置く。カタログへ書こうとしたら理由を添えて落とす。
func TestResolveMySQLVerificationRejectsSecretsInCatalog(t *testing.T) {
	base := `
database_environments: [staging]
parameter_groups:
  blue-mysql84-v1:
    template_path: generated/blue.yaml
%s
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
%s
`
	cases := []struct {
		name        string
		root, perDB string
		want        string
	}{
		{
			name: "ルートに user",
			root: "mysql_verification:\n  user: verifier",
			want: "mysql_verification.user はカタログへ書かない",
		},
		{
			name: "ルートに password",
			root: "mysql_verification:\n  password: s3cret",
			want: "mysql_verification.password はカタログへ書かない",
		},
		{
			name:  "接続配下に user",
			perDB: "            mysql_verification:\n              user: verifier",
			want:  "mysql_verification.user はカタログへ書かない",
		},
		{
			name: "ルートにキー誤字",
			root: "mysql_verification:\n  parameter_nmae: /typo",
			want: "mysql_verification has unknown keys: parameter_nmae",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			content := strings.Replace(base, "%s", testCase.root, 1)
			content = strings.Replace(content, "%s", testCase.perDB, 1)
			_, err := Generate(catalogFrom(t, content), testInventory(t), "staging")
			if err == nil {
				t.Fatal("Generate succeeded, want failure")
			}
			if !strings.Contains(err.Error(), testCase.want) {
				t.Errorf("error = %v, want it to contain %q", err, testCase.want)
			}
		})
	}
}
