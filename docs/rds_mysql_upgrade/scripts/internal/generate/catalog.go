// Package generate は移行カタログと RDS インベントリから Blue/Green 実行設定
// （config/blue-green/<環境>.deployment.yml）を組み立てる。
//
// AWS を一切呼ばない。「収集と判定を分離する」というリポジトリの方針の、判定側にあたる。
// 生成単位は RDS DB インスタンスであり、同じ rds_instance を指す接続は
// 1 つの Blue/Green deployment にまとめる。
package generate

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"

	"rds-mysql-upgrade/scripts/internal/common"
)

// 移行先の共通ターゲット。カタログで engine_version を省略した接続はこの値へ上げる。
// RDS で利用可能なバージョンかは describe-db-engine-versions で確認する。
const DefaultTargetEngineVersion = "8.4.11"

// カタログからの生成は parameter_store 固定である。plaintext / prompt は
// 生成後の設定ファイルを手で書き換えて使う（実行時ライブラリは引き続き対応する）。
const GeneratedMySQLAuthMethod = "parameter_store"

const defaultMySQLPort = 3306

// Catalog は人が管理する移行カタログである。
// トップレベルの未知キーは検証しない（メモや将来の節を許す）。
type Catalog struct {
	Applications         map[string]*Application    `yaml:"applications"`
	DatabaseEnvironments []string                   `yaml:"database_environments"`
	ParameterGroups      map[string]*ParameterGroup `yaml:"parameter_groups"`
	// MySQLVerification は全 DB 共通の既定値である。接続配下の指定が優先する。
	MySQLVerification *MySQLVerificationInput `yaml:"mysql_verification"`
}

type Application struct {
	Connections map[string]*Connection `yaml:"connections"`
}

type Connection struct {
	Environments map[string]*Binding `yaml:"environments"`
}

// Binding は「その接続が、ある環境で実際に繋がっている先」である。
// Extra には未知のキーが入る。誤字を黙って無視しないために検証する。
type Binding struct {
	RDSInstance       string                  `yaml:"rds_instance"`
	SchemaName        string                  `yaml:"schema_name"`
	Target            *Target                 `yaml:"target"`
	MySQLVerification *MySQLVerificationInput `yaml:"mysql_verification"`
	Extra             map[string]any          `yaml:",inline"`
}

type Target struct {
	DBParameterGroupName string         `yaml:"db_parameter_group_name"`
	EngineVersion        string         `yaml:"engine_version"`
	DBInstanceClass      string         `yaml:"db_instance_class"`
	Extra                map[string]any `yaml:",inline"`
}

type ParameterGroup struct {
	TemplatePath string `yaml:"template_path"`
}

// MySQLVerificationInput はカタログ側の指定である。ポインタで「未指定」と
// 「明示的に空」を区別し、ルート既定値とのキー単位マージを成立させる。
// user と password は持たない——ユーザー名もパスワードも SSM 側へ置く。
type MySQLVerificationInput struct {
	Enabled           *bool          `yaml:"enabled"`
	ParameterName     *string        `yaml:"parameter_name"`
	UserParameterName *string        `yaml:"user_parameter_name"`
	SSLCA             *string        `yaml:"ssl_ca"`
	Port              *int           `yaml:"port"`
	Extra             map[string]any `yaml:",inline"`
}

// ReadCatalog はカタログ YAML を読む。
func ReadCatalog(path string) (*Catalog, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read catalog %s: %w", path, err)
	}
	var value Catalog
	if err := yaml.Unmarshal(content, &value); err != nil {
		return nil, fmt.Errorf("cannot parse catalog %s: %w", path, err)
	}
	return &value, nil
}

// unknownKeys は inline で拾った未知キーを、決定的な順序で並べる。
func unknownKeys(extra map[string]any) []string {
	return common.SortedKeys(extra)
}

// checkMySQLVerification はカタログ側の指定を検証する。
// ルート既定値と接続配下で共通に使う。
func checkMySQLVerification(given *MySQLVerificationInput, context string) error {
	if given == nil {
		return nil
	}
	// user / password は構造体に無いため未知キーとしても弾かれるが、
	// 書きたくなる値なので理由を明示して先に落とす。
	for _, secretKey := range []string{"password", "user"} {
		if _, written := given.Extra[secretKey]; written {
			return fmt.Errorf(
				"%s.%s はカタログへ書かない。"+
					"ユーザー名とパスワードは SSM Parameter Store の SecureString に置く",
				context, secretKey)
		}
	}
	if keys := unknownKeys(given.Extra); len(keys) > 0 {
		return fmt.Errorf("%s has unknown keys: %s", context, strings.Join(keys, ", "))
	}
	return nil
}

// resolveMySQLVerification はルート既定値へ接続配下の指定をキー単位で重ねる。
//
// 環境（development / staging / production）は AWS アカウントが分かれるため、
// 同じパラメータ名を全環境で共通に使える。DB ごとに分ける場合だけ接続配下へ書く。
func resolveMySQLVerification(defaults, given *MySQLVerificationInput, context string) (MySQLVerification, error) {
	if err := checkMySQLVerification(given, context+".mysql_verification"); err != nil {
		return MySQLVerification{}, err
	}

	resolved := MySQLVerification{AuthMethod: GeneratedMySQLAuthMethod, Port: defaultMySQLPort}
	for _, layer := range []*MySQLVerificationInput{defaults, given} {
		if layer == nil {
			continue
		}
		if layer.Enabled != nil {
			resolved.Enabled = *layer.Enabled
		}
		if layer.ParameterName != nil {
			resolved.ParameterName = *layer.ParameterName
		}
		if layer.UserParameterName != nil {
			resolved.UserParameterName = *layer.UserParameterName
		}
		if layer.SSLCA != nil {
			resolved.SSLCA = *layer.SSLCA
		}
		if layer.Port != nil && *layer.Port != 0 {
			resolved.Port = *layer.Port
		}
	}

	// enabled のときだけ、パスワードとユーザー名の両方の在り処を要求する。
	if resolved.Enabled {
		required := []struct {
			key   string
			value string
		}{
			{"parameter_name", resolved.ParameterName},
			{"user_parameter_name", resolved.UserParameterName},
		}
		for _, item := range required {
			if item.value == "" {
				return MySQLVerification{}, fmt.Errorf(
					"%s.mysql_verification.%s が必要である"+
						"（接続配下かルートの mysql_verification のいずれかで指定する。"+
						"生成される auth_method は parameter_store 固定）", context, item.key)
			}
		}
	}
	return resolved, nil
}

// resolveTarget は target を解決する。db_parameter_group_name 以外は省略できる。
//
// engine_version を省略した場合は共通ターゲット（DefaultTargetEngineVersion）へ上げる。
// Blue の値を踏襲しない——それでは移行にならない。
// db_instance_class を省略した場合は Blue の実値を踏襲する。
func resolveTarget(given *Target, instance *common.DBInstance, context string) (*Target, error) {
	if given == nil {
		return nil, fmt.Errorf("%s.target: db_parameter_group_name is required", context)
	}
	if keys := unknownKeys(given.Extra); len(keys) > 0 {
		return nil, fmt.Errorf("%s.target has unknown keys: %s", context, strings.Join(keys, ", "))
	}
	if strings.TrimSpace(given.DBParameterGroupName) == "" {
		return nil, fmt.Errorf("%s.target: db_parameter_group_name is required", context)
	}

	resolved := &Target{
		DBParameterGroupName: given.DBParameterGroupName,
		EngineVersion:        given.EngineVersion,
		DBInstanceClass:      given.DBInstanceClass,
	}
	if strings.TrimSpace(resolved.EngineVersion) == "" {
		resolved.EngineVersion = DefaultTargetEngineVersion
	}
	if strings.TrimSpace(resolved.DBInstanceClass) == "" {
		if strings.TrimSpace(instance.DBInstanceClass) == "" {
			return nil, fmt.Errorf("%s: DBInstanceClass is required", context)
		}
		resolved.DBInstanceClass = instance.DBInstanceClass
	}
	return resolved, nil
}

var majorMinorPattern = regexp.MustCompile(`^(\d+)\.(\d+)`)

// normalizeMajorMinor は RDS の EngineVersion を major.minor へ丸める。
// 自動マイナーバージョンアップグレードによるパッチ差分を判定へ持ち込まないためである。
func normalizeMajorMinor(version, context string) (string, error) {
	match := majorMinorPattern.FindStringSubmatch(version)
	if match == nil {
		return "", fmt.Errorf("%s: invalid RDS EngineVersion: %q", context, version)
	}
	return match[1] + "." + match[2], nil
}
