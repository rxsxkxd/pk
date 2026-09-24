// Package deployconfig は実行設定 YAML（config/blue-green/<環境>.deployment.yml）を読む。
//
// scripts/lib/deployment_config.rb（CI から到達する側）と**同じ意味づけとメッセージ**にしてある。
// scripts/ と tools/ はコードを共有しない方針のため、tools/ 側の読み取りはここで持つ。
//
//	Required … 空・未定義なら `<パス> が未定義である`
//	Optional … 空・未定義なら既定値
//	Service  … services.<名前>（無ければ `services.<名前> が未定義である`）
//
// キーはドット区切りで入れ子を辿る（例: actions.cleanup）。スカラーは文字列にして返す。
package deployconfig

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config は設定の一部（トップレベル、または services.<名前>）である。
type Config struct {
	document map[string]any
	prefix   string
}

// Load は設定ファイルを読む。
func Load(path string) (*Config, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s: YAML を読み込めなかった: %v", path, err)
	}
	var document map[string]any
	if err := yaml.Unmarshal(content, &document); err != nil {
		return nil, fmt.Errorf("%s: YAML を解析できなかった: %v", path, err)
	}
	if document == nil {
		return nil, fmt.Errorf("%s: YAML がマッピングではない", path)
	}
	return &Config{document: document}, nil
}

// Service は services.<名前> を返す。
func (c *Config) Service(name string) (*Config, error) {
	services, _ := c.document["services"].(map[string]any)
	entry, ok := services[name].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("services.%s が未定義である", name)
	}
	return &Config{document: entry, prefix: "services." + name}, nil
}

// Required は必須項目を返す。空・未定義ならエラー。
func (c *Config) Required(key string) (string, error) {
	value, ok := c.lookup(key)
	if !ok {
		return "", fmt.Errorf("%s が未定義である", c.qualify(key))
	}
	return value, nil
}

// Optional は任意項目を返す。空・未定義なら fallback。
func (c *Config) Optional(key, fallback string) string {
	if value, ok := c.lookup(key); ok {
		return value
	}
	return fallback
}

func (c *Config) lookup(key string) (string, bool) {
	var node any = c.document
	for _, part := range strings.Split(key, ".") {
		mapping, ok := node.(map[string]any)
		if !ok {
			return "", false
		}
		node = mapping[part]
	}
	if node == nil {
		return "", false
	}
	switch node.(type) {
	case map[string]any, []any:
		return "", false
	}
	value := fmt.Sprint(node)
	return value, value != ""
}

func (c *Config) qualify(key string) string {
	if c.prefix == "" {
		return key
	}
	return c.prefix + "." + key
}
