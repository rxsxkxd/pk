package common

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// 再収集を促すときの案内。収集器と生成器で同じ文言を使う。
const recollectHint = "collect it again with go -C scripts run ./collect_rds_instance_inventory"

// Inventory は収集器が書き、生成器が読む RDS の事実情報である。
//
// DBInstances は describe-db-instances の応答をそのまま保持する。
// ParameterGroups は確認用に採取したパラメータグループの実値である。
type Inventory struct {
	AwsRegion       string                          `json:"aws_region"`
	DBInstances     []*DBInstance                   `json:"DBInstances"`
	ParameterGroups map[string]*ParameterGroupFacts `json:"ParameterGroups"`
}

// DBInstance は describe-db-instances の要素である。
//
// 生成で使う値には型付きで触れるが、**応答は raw のまま保持して書き戻す**。
// インベントリは人がレビューする事実情報でもあるため、収集器が知らない項目
// （ParameterApplyStatus など）や項目の並びを落とさない。
type DBInstance struct {
	DBInstanceIdentifier string
	Engine               string
	EngineVersion        string
	DBInstanceClass      string
	DBParameterGroups    []DBParameterGroupRef

	// raw は describe-db-instances の応答そのままである。
	raw json.RawMessage
}

type DBParameterGroupRef struct {
	DBParameterGroupName string `json:"DBParameterGroupName"`
}

// dbInstanceFields は raw から型付きの値を取り出すための射影である。
type dbInstanceFields struct {
	DBInstanceIdentifier string                `json:"DBInstanceIdentifier"`
	Engine               string                `json:"Engine"`
	EngineVersion        string                `json:"EngineVersion"`
	DBInstanceClass      string                `json:"DBInstanceClass"`
	DBParameterGroups    []DBParameterGroupRef `json:"DBParameterGroups"`
}

// UnmarshalJSON は応答を raw として保持しつつ、必要な項目を取り出す。
func (instance *DBInstance) UnmarshalJSON(data []byte) error {
	var fields dbInstanceFields
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	instance.DBInstanceIdentifier = fields.DBInstanceIdentifier
	instance.Engine = fields.Engine
	instance.EngineVersion = fields.EngineVersion
	instance.DBInstanceClass = fields.DBInstanceClass
	instance.DBParameterGroups = fields.DBParameterGroups
	instance.raw = append(json.RawMessage(nil), data...)
	return nil
}

// MarshalJSON は読み込んだ応答をそのまま書き戻す。
func (instance *DBInstance) MarshalJSON() ([]byte, error) {
	if instance.raw == nil {
		return json.Marshal(dbInstanceFields{
			DBInstanceIdentifier: instance.DBInstanceIdentifier,
			Engine:               instance.Engine,
			EngineVersion:        instance.EngineVersion,
			DBInstanceClass:      instance.DBInstanceClass,
			DBParameterGroups:    instance.DBParameterGroups,
		})
	}
	return instance.raw, nil
}

// ParameterGroupFacts は確認用に採取するパラメータグループの実値である。
// 採取する対象は collect 側で決める（現在は time_zone のみ）。
// パラメータ名をキーにしておき、後から対象を増やしても構造を変えずに済むようにする。
type ParameterGroupFacts struct {
	Parameters map[string]ParameterValue `json:"Parameters"`
}

// ParameterValue は 1 つのパラメータの実値と、その由来である。
// Source は user / system / engine-default のいずれかで、
// engine-default ならパラメータグループでは未設定（エンジン既定値）を意味する。
type ParameterValue struct {
	Value  string `json:"Value"`
	Source string `json:"Source"`
}

// Parameter は採取済みのパラメータを 1 件引く。採取していなければ false を返す。
func (facts *ParameterGroupFacts) Parameter(name string) (ParameterValue, bool) {
	value, found := facts.Parameters[name]
	return value, found
}

// ReadInventory はインベントリ JSON を読み、生成に必要な項目が揃っているかを確かめる。
// 欠けている場合は黙って項目を落とさず、再収集を促して失敗する。
func ReadInventory(path string) (*Inventory, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read RDS inventory %s: %w", path, err)
	}
	var value Inventory
	if err := json.Unmarshal(content, &value); err != nil {
		return nil, fmt.Errorf("cannot read RDS inventory %s: %w", path, err)
	}
	if value.DBInstances == nil {
		return nil, fmt.Errorf("RDS inventory has no DBInstances array: %s", path)
	}
	if strings.TrimSpace(value.AwsRegion) == "" {
		return nil, fmt.Errorf("RDS inventory has no aws_region: %s; %s", path, recollectHint)
	}
	if value.ParameterGroups == nil {
		return nil, fmt.Errorf("RDS inventory has no ParameterGroups object: %s; %s", path, recollectHint)
	}
	return &value, nil
}

// WriteInventory はインベントリ JSON を原子的に書く。
func WriteInventory(path string, value *Inventory) error {
	return WriteJSON(path, value)
}

// IndexInstances は DB インスタンス識別子で引けるようにする。
// 重複は入力の誤りとして落とす。
func (inventory *Inventory) IndexInstances() (map[string]*DBInstance, error) {
	indexed := map[string]*DBInstance{}
	for _, instance := range inventory.DBInstances {
		if instance == nil || instance.DBInstanceIdentifier == "" {
			continue
		}
		if _, duplicated := indexed[instance.DBInstanceIdentifier]; duplicated {
			return nil, fmt.Errorf(
				"RDS inventory contains duplicate DB instance: %s", instance.DBInstanceIdentifier)
		}
		indexed[instance.DBInstanceIdentifier] = instance
	}
	return indexed, nil
}

// SourceParameterGroupName は Blue のパラメータグループ名を引く。
// 複数関連付いている構成は判定できないため、明示的に落とす。
func (instance *DBInstance) SourceParameterGroupName(context string) (string, error) {
	if len(instance.DBParameterGroups) != 1 {
		return "", fmt.Errorf(
			"%s: RDS inventory must contain exactly one DBParameterGroups entry", context)
	}
	name := instance.DBParameterGroups[0].DBParameterGroupName
	if name == "" {
		return "", fmt.Errorf("%s: DBParameterGroups[0].DBParameterGroupName is required", context)
	}
	return name, nil
}

// ParameterGroupOf は、指定したパラメータグループの採取済み実値を返す。
func (inventory *Inventory) ParameterGroupOf(parameterGroupName, context string) (*ParameterGroupFacts, error) {
	found := inventory.ParameterGroups[parameterGroupName]
	if found == nil {
		return nil, fmt.Errorf("%s: RDS inventory has no ParameterGroups entry for %s; %s",
			context, parameterGroupName, recollectHint)
	}
	return found, nil
}
