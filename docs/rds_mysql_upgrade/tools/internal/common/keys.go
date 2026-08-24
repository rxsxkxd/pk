package common

import "sort"

// SortedKeys は map のキーを決定的な順序で返す。
// 生成結果とエラーメッセージを実行ごとに同じにするために使う。
func SortedKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// Contains は文字列スライスに値が含まれるかを返す。
func Contains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}
