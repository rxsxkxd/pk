// Package common は、収集（collect）と定義ファイル生成（generate）の両方が使う
// 共有部分を持つ。RDS インベントリの型は収集器が書き生成器が読む「契約」なので、
// 片側だけ変えて黙って壊れないようここに一本化する。
package common

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// 生成物は人がレビューし CI が読む。秘匿値を含まないため通常のファイル権限にする。
const outputFileMode = 0o644

// WriteAtomic は同一ディレクトリの一時ファイルへ書いてから rename する。
// 途中で失敗しても出力先に壊れたファイルを残さない。
// write には実際の書き出し処理を渡す（JSON / YAML でエンコーダが違うため）。
func WriteAtomic(path string, write func(file *os.File) error) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)

	if err := write(temporary); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	// CreateTemp は 0600 で作るため、読める権限へ直してから置き換える。
	if err := os.Chmod(temporaryPath, outputFileMode); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

// WriteJSON は値をインデント 2 の JSON として原子的に書く。
func WriteJSON(path string, value any) error {
	return WriteAtomic(path, func(file *os.File) error {
		encoder := json.NewEncoder(file)
		encoder.SetIndent("", "  ")
		encoder.SetEscapeHTML(false)
		return encoder.Encode(value)
	})
}
