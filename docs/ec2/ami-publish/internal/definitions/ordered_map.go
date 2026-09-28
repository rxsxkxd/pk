package definitions

import (
	"fmt"

	"gopkg.in/yaml.v3"
)

// Map は、キーの並び順を保ったまま YAML に書き出すマップ。
//
// Go の map はキーの順序が決まらず、yaml.v3 は map のキーを並べ替えて出力する。
// CloudFormation テンプレートや buildspec は並び順に意味がある（読みやすさ・レビューの差分）ため、
// 定義はすべてこの型で書き、毎回同じ順序で出力する。
type Map []Entry

// Entry は Map の 1 項目。
type Entry struct {
	Key   string
	Value any
}

// M は「キー, 値, キー, 値, ...」の並びから Map を作る。
// 定義の書き間違い（キーが文字列でない、数が合わない）は生成時に即座に分かるよう panic する。
func M(keyValues ...any) Map {
	if len(keyValues)%2 != 0 {
		panic(fmt.Sprintf("definitions.M: キーと値の数が合わない（%d 個）", len(keyValues)))
	}
	result := make(Map, 0, len(keyValues)/2)
	for index := 0; index < len(keyValues); index += 2 {
		key, ok := keyValues[index].(string)
		if !ok {
			panic(fmt.Sprintf("definitions.M: キーが文字列ではない: %#v", keyValues[index]))
		}
		result = append(result, Entry{Key: key, Value: keyValues[index+1]})
	}
	return result
}

// MarshalYAML は、項目を追加した順のまま YAML のマッピングにする。
func (m Map) MarshalYAML() (any, error) {
	node := &yaml.Node{Kind: yaml.MappingNode}
	for _, entry := range m {
		var value yaml.Node
		if err := value.Encode(entry.Value); err != nil {
			return nil, fmt.Errorf("%s: %w", entry.Key, err)
		}
		node.Content = append(node.Content,
			&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: entry.Key},
			&value)
	}
	return node, nil
}

// CloudFormation の組み込み関数。短縮形（!Ref など）ではなく完全形で出力する。

// Ref は Ref を返す。
func Ref(logicalName string) Map { return M("Ref", logicalName) }

// Sub は Fn::Sub を返す。
func Sub(format string) Map { return M("Fn::Sub", format) }

// GetAtt は Fn::GetAtt を返す。
func GetAtt(logicalName, attribute string) Map {
	return M("Fn::GetAtt", []any{logicalName, attribute})
}
