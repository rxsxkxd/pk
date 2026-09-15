package generate

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

	"rds-mysql-upgrade/tools/internal/common"
)

// Deployment は生成する設定ファイルの全体である。
// 出力のキー順はこの構造体のフィールド順で決まる。
type Deployment struct {
	Environment string              `yaml:"environment"`
	AwsRegion   string              `yaml:"aws_region"`
	Services    map[string]*Service `yaml:"services"`
}

// Service は 1 つの Blue/Green deployment、すなわち 1 つの RDS DB インスタンスである。
type Service struct {
	SourceDBInstanceIdentifier       string                     `yaml:"source_db_instance_identifier"`
	SourceEngineVersion              string                     `yaml:"source_engine_version"`
	SourceDBParameterGroupName       string                     `yaml:"source_db_parameter_group_name"`
	TargetEngineVersion              string                     `yaml:"target_engine_version"`
	TargetDBInstanceClass            string                     `yaml:"target_db_instance_class"`
	TargetDBParameterGroupName       string                     `yaml:"target_db_parameter_group_name"`
	TargetParameterGroupTemplatePath string                     `yaml:"target_parameter_group_template_path"`
	ProtectionSnapshotIdentifier     string                     `yaml:"protection_snapshot_identifier"`
	FinalSnapshotIdentifier          string                     `yaml:"final_snapshot_identifier"`
	Schemas                          []string                   `yaml:"schemas"`
	SourceDBParameters               map[string]SourceParameter `yaml:"source_db_parameters"`
	MySQLVerification                MySQLVerification          `yaml:"mysql_verification"`
	Actions                          Actions                    `yaml:"actions"`
}

// SourceParameter は Blue のパラメータグループから採取した実値である。
//
// **確認用である。実行スクリプトは参照せず、判定にも使わない。**
// 切替の前後で値が変わらないことを人がレビューするために載せる
// （time_zone の論点は reference/mysql-timezone-problem-summary.md）。
// Source が engine-default ならパラメータグループでは未設定である。
type SourceParameter struct {
	Value  string `yaml:"value"`
	Source string `yaml:"source"`
}

type MySQLVerification struct {
	Enabled           bool   `yaml:"enabled"`
	AuthMethod        string `yaml:"auth_method"`
	ParameterName     string `yaml:"parameter_name"`
	UserParameterName string `yaml:"user_parameter_name"`
	SSLCA             string `yaml:"ssl_ca"`
	Port              int    `yaml:"port"`
}

// Actions は人の承認を表す。生成時は常に pending で、承認は人が書き換える。
type Actions struct {
	Build             string `yaml:"build"`
	Switchover        string `yaml:"switchover"`
	SwitchoverTimeout int    `yaml:"switchover_timeout"`
	Cleanup           string `yaml:"cleanup"`
}

// Generate は指定環境の設定を組み立てる。
func Generate(catalog *Catalog, inventory *common.Inventory, environmentName string) (*Deployment, error) {
	known, err := validateCatalog(catalog, environmentName)
	if err != nil {
		return nil, err
	}
	instances, err := inventory.IndexInstances()
	if err != nil {
		return nil, err
	}

	services := map[string]*Service{}
	for _, applicationName := range common.SortedKeys(catalog.Applications) {
		applicationContext := "applications." + applicationName
		application := catalog.Applications[applicationName]
		if application == nil || len(application.Connections) == 0 {
			return nil, fmt.Errorf("%s: connections is required", applicationContext)
		}

		for _, connectionName := range common.SortedKeys(application.Connections) {
			connectionContext := applicationContext + ".connections." + connectionName
			connection := application.Connections[connectionName]
			if connection == nil {
				continue
			}
			// 環境名の誤字は、その環境の生成時に黙って無視されてしまう。
			// どの環境を生成していても全件を検証する。
			for _, name := range common.SortedKeys(connection.Environments) {
				if !known[name] {
					return nil, fmt.Errorf(
						"%s.environments.%s: catalog.database_environments に無い環境である",
						connectionContext, name)
				}
			}

			binding := connection.Environments[environmentName]
			if binding == nil {
				continue
			}
			context := connectionContext + ".environments." + environmentName
			candidate, schemaName, err := buildService(catalog, inventory, instances, binding, context)
			if err != nil {
				return nil, err
			}

			existing := services[candidate.SourceDBInstanceIdentifier]
			if existing == nil {
				services[candidate.SourceDBInstanceIdentifier] = candidate
				continue
			}
			// 同じインスタンスを指す接続は 1 つの deployment にまとめる。
			// 重複して書かれた設定は一致していなければならない。
			if err := requireSameDeployment(existing, candidate, context); err != nil {
				return nil, err
			}
			if !common.Contains(existing.Schemas, schemaName) {
				existing.Schemas = append(existing.Schemas, schemaName)
				sort.Strings(existing.Schemas)
			}
		}
	}

	if len(services) == 0 {
		return nil, fmt.Errorf("no connection is defined for the environment: %s", environmentName)
	}
	return &Deployment{
		Environment: environmentName,
		AwsRegion:   inventory.AwsRegion,
		Services:    services,
	}, nil
}

// ConnectionRef は、ある環境で 1 つの RDS インスタンスを指している接続である。
// 生成結果（deployment.yml）にはアプリ名が残らないため、レポート側が
// 「この切替で影響を受けるのは誰か」を辿るために使う。
type ConnectionRef struct {
	Application string
	Connection  string
	SchemaName  string
	RDSInstance string
}

// ConnectionsIn は指定環境の接続を、アプリ名・接続名の順で列挙する。
// 検証は行わない（Generate が済ませている前提で、レポートの材料として使う）。
func ConnectionsIn(catalog *Catalog, environmentName string) []ConnectionRef {
	var refs []ConnectionRef
	for _, applicationName := range common.SortedKeys(catalog.Applications) {
		application := catalog.Applications[applicationName]
		if application == nil {
			continue
		}
		for _, connectionName := range common.SortedKeys(application.Connections) {
			connection := application.Connections[connectionName]
			if connection == nil {
				continue
			}
			binding := connection.Environments[environmentName]
			if binding == nil {
				continue
			}
			refs = append(refs, ConnectionRef{
				Application: applicationName,
				Connection:  connectionName,
				SchemaName:  strings.TrimSpace(binding.SchemaName),
				RDSInstance: strings.TrimSpace(binding.RDSInstance),
			})
		}
	}
	return refs
}

// validateCatalog はカタログの骨格を確かめ、既知の環境名の集合を返す。
func validateCatalog(catalog *Catalog, environmentName string) (map[string]bool, error) {
	if len(catalog.Applications) == 0 {
		return nil, fmt.Errorf("catalog.applications must be a non-empty mapping")
	}
	if len(catalog.DatabaseEnvironments) == 0 {
		return nil, fmt.Errorf("catalog.database_environments must be a non-empty list")
	}
	known := map[string]bool{}
	for _, name := range catalog.DatabaseEnvironments {
		known[name] = true
	}
	if !known[environmentName] {
		return nil, fmt.Errorf("unknown environment: %s（catalog.database_environments: %s）",
			environmentName, strings.Join(catalog.DatabaseEnvironments, ", "))
	}
	if len(catalog.ParameterGroups) == 0 {
		return nil, fmt.Errorf("catalog.parameter_groups must be a non-empty mapping")
	}
	if err := checkMySQLVerification(catalog.MySQLVerification, "mysql_verification"); err != nil {
		return nil, err
	}
	return known, nil
}

// buildService は 1 つの接続から 1 つの deployment 候補を組み立てる。
// 併せて、集約に使うスキーマ名を返す。
func buildService(
	catalog *Catalog,
	inventory *common.Inventory,
	instances map[string]*common.DBInstance,
	binding *Binding,
	context string,
) (*Service, string, error) {
	if keys := unknownKeys(binding.Extra); len(keys) > 0 {
		return nil, "", fmt.Errorf("%s has unknown keys: %s", context, strings.Join(keys, ", "))
	}
	sourceID := strings.TrimSpace(binding.RDSInstance)
	if sourceID == "" {
		return nil, "", fmt.Errorf("%s: rds_instance is required", context)
	}
	schemaName := strings.TrimSpace(binding.SchemaName)
	if schemaName == "" {
		return nil, "", fmt.Errorf("%s: schema_name is required", context)
	}

	instance := instances[sourceID]
	if instance == nil {
		return nil, "", fmt.Errorf(
			"%s: source DB instance is absent from inventory: %s", context, sourceID)
	}
	if instance.Engine != "mysql" {
		return nil, "", fmt.Errorf(
			"%s: source DB instance Engine must be mysql, got %q", context, instance.Engine)
	}

	target, err := resolveTarget(binding.Target, instance, context)
	if err != nil {
		return nil, "", err
	}
	parameterGroup := catalog.ParameterGroups[target.DBParameterGroupName]
	if parameterGroup == nil {
		return nil, "", fmt.Errorf("%s: catalog.parameter_groups に無い: %s",
			context, target.DBParameterGroupName)
	}
	if strings.TrimSpace(parameterGroup.TemplatePath) == "" {
		return nil, "", fmt.Errorf("parameter_groups.%s: template_path is required",
			target.DBParameterGroupName)
	}

	sourceGroupName, err := instance.SourceParameterGroupName(context)
	if err != nil {
		return nil, "", err
	}
	sourceVersion, err := normalizeMajorMinor(instance.EngineVersion, context)
	if err != nil {
		return nil, "", err
	}
	sourceGroup, err := inventory.ParameterGroupOf(sourceGroupName, context)
	if err != nil {
		return nil, "", err
	}
	sourceParameters := map[string]SourceParameter{}
	for name, parameter := range sourceGroup.Parameters {
		sourceParameters[name] = SourceParameter{Value: parameter.Value, Source: parameter.Source}
	}
	verification, err := resolveMySQLVerification(catalog.MySQLVerification, binding.MySQLVerification, context)
	if err != nil {
		return nil, "", err
	}

	return &Service{
		SourceDBInstanceIdentifier:       sourceID,
		SourceEngineVersion:              sourceVersion,
		SourceDBParameterGroupName:       sourceGroupName,
		TargetEngineVersion:              target.EngineVersion,
		TargetDBInstanceClass:            target.DBInstanceClass,
		TargetDBParameterGroupName:       target.DBParameterGroupName,
		TargetParameterGroupTemplatePath: parameterGroup.TemplatePath,
		ProtectionSnapshotIdentifier:     sourceID + "-pre-bg",
		FinalSnapshotIdentifier:          sourceID + "-final",
		// 影響範囲。切替前のレビューで使う。
		Schemas: []string{schemaName},
		// 確認用。Blue のパラメータグループから採取した実値。
		SourceDBParameters: sourceParameters,
		MySQLVerification:  verification,
		Actions: Actions{
			Build:             "pending",
			Switchover:        "pending",
			SwitchoverTimeout: 300,
			Cleanup:           "pending",
		},
	}, schemaName, nil
}

// requireSameDeployment は、同じインスタンスを指す接続同士で矛盾が無いことを確かめる。
func requireSameDeployment(existing, candidate *Service, context string) error {
	mismatches := []struct {
		key           string
		before, after any
	}{
		{"target_engine_version", existing.TargetEngineVersion, candidate.TargetEngineVersion},
		{"target_db_instance_class", existing.TargetDBInstanceClass, candidate.TargetDBInstanceClass},
		{"target_db_parameter_group_name", existing.TargetDBParameterGroupName, candidate.TargetDBParameterGroupName},
		{"mysql_verification", existing.MySQLVerification, candidate.MySQLVerification},
		{"source_db_parameters",
			fmt.Sprint(common.SortedKeys(existing.SourceDBParameters), existing.SourceDBParameters),
			fmt.Sprint(common.SortedKeys(candidate.SourceDBParameters), candidate.SourceDBParameters)},
	}
	for _, mismatch := range mismatches {
		if mismatch.before != mismatch.after {
			return fmt.Errorf("%s: %s を指す他の接続と %s が食い違う（%v と %v）",
				context, existing.SourceDBInstanceIdentifier, mismatch.key,
				mismatch.before, mismatch.after)
		}
	}
	return nil
}

// Write は生成した設定を原子的に書く。既存の deployment.yml と同じ 2 スペース字下げにする。
func Write(path string, document *Deployment) error {
	return common.WriteAtomic(path, func(file *os.File) error {
		encoder := yaml.NewEncoder(file)
		encoder.SetIndent(2)
		if err := encoder.Encode(document); err != nil {
			return err
		}
		return encoder.Close()
	})
}
