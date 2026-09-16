// Package cfn は Step 2 の CloudFormation テンプレートから、DB パラメータグループ
// の宣言値を読む。
//
// **短縮記法（!Ref / !Sub）を長形式へ正規化して読む。** yaml.Unmarshal へ直接 map を
// 渡すとタグが黙って捨てられ、`!Ref Workers` が "Workers" という文字列に化けて
// RDS の実値と誤って比較されるため、yaml.Node を経由する。
//
// 値が組み込み関数の項目は、CloudFormation のパラメータ解決なしには実値が決まらない。
// 比較すると誤ったドリフトになるため Declared には入れず、Unresolved で示す。
// fixture とテストは examples/cfn-shorthand/ にある。
package cfn

import (
	"fmt"
	"os"
	"regexp"
	"sort"

	"gopkg.in/yaml.v3"
)

// ParameterGroup はテンプレートが宣言している DB パラメータグループの内容である。
type ParameterGroup struct {
	// Declared は実値が決まっているパラメータ（パラメータ名 → 値）。
	Declared map[string]string
	// Unresolved は値が組み込み関数のパラメータ（パラメータ名 → Ref / Fn::Sub など）。
	Unresolved map[string]string
}

// Parameter は宣言値を 1 件引く。
// 組み込み関数なら resolved=false となり、intrinsic にその種類が入る。
func (group *ParameterGroup) Parameter(name string) (value string, resolved bool, intrinsic string) {
	if intrinsic, found := group.Unresolved[name]; found {
		return "", false, intrinsic
	}
	value, found := group.Declared[name]
	if !found {
		return "", false, ""
	}
	return value, true, ""
}

// ReadDBParameterGroup は テンプレートから最初の AWS::RDS::DBParameterGroup を読む。
func ReadDBParameterGroup(path string) (*ParameterGroup, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	var root yaml.Node
	if err := yaml.Unmarshal(content, &root); err != nil {
		return nil, fmt.Errorf("%s: YAML を解析できない: %w", path, err)
	}
	template, isMap := NodeToAny(&root).(map[string]any)
	if !isMap {
		return nil, fmt.Errorf("%s: テンプレートの最上位がマッピングではない", path)
	}
	resources, found := template["Resources"].(map[string]any)
	if !found {
		return nil, fmt.Errorf("%s: Resources が見つからない", path)
	}

	group := &ParameterGroup{Declared: map[string]string{}, Unresolved: map[string]string{}}
	for _, raw := range resources {
		resource, isMap := raw.(map[string]any)
		if !isMap || resource["Type"] != "AWS::RDS::DBParameterGroup" {
			continue
		}
		properties, _ := resource["Properties"].(map[string]any)
		parameters, _ := properties["Parameters"].(map[string]any)
		for name, value := range parameters {
			switch typed := value.(type) {
			case map[string]any:
				group.Unresolved[name] = "Fn::*"
				for key := range typed {
					group.Unresolved[name] = key
					break
				}
			case []any:
				group.Unresolved[name] = "Fn::*"
			default:
				group.Declared[name] = fmt.Sprint(value)
			}
		}
		return group, nil
	}
	return nil, fmt.Errorf("%s: AWS::RDS::DBParameterGroup が見つからない", path)
}

// IntrinsicKey は CloudFormation の短縮記法タグ（!Ref / !Sub など）を
// 長形式のキー（Ref / Fn::Sub）へ変換する。CFn 以外のタグでは空文字を返す。
func IntrinsicKey(tag string) string {
	if len(tag) < 2 || tag[0] != '!' || tag[1] == '!' {
		return ""
	}
	name := tag[1:]
	if name == "Ref" || name == "Condition" {
		return name
	}
	return "Fn::" + name
}

// NodeToAny は短縮記法を長形式へ正規化しながら YAML を Go の値へ変換する。
func NodeToAny(node *yaml.Node) any {
	if node == nil {
		return nil
	}
	if node.Kind == yaml.DocumentNode {
		if len(node.Content) == 0 {
			return nil
		}
		return NodeToAny(node.Content[0])
	}
	if key := IntrinsicKey(node.Tag); key != "" {
		return map[string]any{key: untaggedToAny(node)}
	}
	return untaggedToAny(node)
}

func untaggedToAny(node *yaml.Node) any {
	switch node.Kind {
	case yaml.MappingNode:
		result := map[string]any{}
		for i := 0; i+1 < len(node.Content); i += 2 {
			result[node.Content[i].Value] = NodeToAny(node.Content[i+1])
		}
		return result
	case yaml.SequenceNode:
		result := make([]any, 0, len(node.Content))
		for _, child := range node.Content {
			result = append(result, NodeToAny(child))
		}
		return result
	default:
		return node.Value
	}
}

// safeParameterName は SQL へ埋め込める識別子だけを通す。
var safeParameterName = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

// ParameterNames はテンプレートが宣言しているパラメータ名を昇順で返す。
//
// 値が組み込み関数の項目（Unresolved）も含める。実値は決まらないが、
// **実効値の収集対象ではある**ためである（収集した値は「比較不能」として表示し、
// ドリフト判定には使わない）。
//
// 名前は SQL の IN リストへ入るため、識別子として安全な文字だけに限る。
// 値は SQL に含めないので、ここを通れば埋め込みは安全である。
func ParameterNames(path string) ([]string, error) {
	group, err := ReadDBParameterGroup(path)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(group.Declared)+len(group.Unresolved))
	for name := range group.Declared {
		names = append(names, name)
	}
	for name := range group.Unresolved {
		names = append(names, name)
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("%s: パラメータが 1 つも宣言されていません。", path)
	}
	sort.Strings(names)
	for _, name := range names {
		if !safeParameterName.MatchString(name) {
			return nil, fmt.Errorf("%s: パラメータ名として扱えない文字が含まれます: %q", path, name)
		}
	}
	return names, nil
}
