package definitions

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// generatedFileHeader は生成した YAML ファイルの先頭に付ける注意書き。
const generatedFileHeader = "# このファイルは cmd/generate-definitions が config/ami_publish.yml から生成した。手で編集しない。\n" +
	"# 変更するときは internal/definitions/ か config/ を直し、再生成して差分をレビューする。\n"

// File は生成する 1 ファイル。Path は出力先ディレクトリからの相対パス。
type File struct {
	Path    string
	Content []byte
}

// GenerateAll は全環境分の CloudFormation テンプレートと、共通の buildspec を生成する。
// repositoryRoot は UserData ファイルなど、設定値が参照するファイルの基準ディレクトリ。
func GenerateAll(configuration Configuration, repositoryRoot string) ([]File, error) {
	var files []File
	add := func(path string, definition Map) error {
		content, err := Render(definition)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		files = append(files, File{Path: path, Content: content})
		return nil
	}

	if err := add("codebuild/ami-publish-buildspec.yml", AMIPublishBuildspec()); err != nil {
		return nil, err
	}
	for _, name := range configuration.EnvironmentNames() {
		environment := configuration.Environments[name]
		userData, err := readUserData(repositoryRoot, environment.LaunchTemplate.UserDataFile)
		if err != nil {
			return nil, fmt.Errorf("environments.%s: %w", name, err)
		}
		directory := "cloudformation/" + name + "/"
		if err := add(directory+"launch-template-stack.yml", LaunchTemplateStack(name, environment, userData)); err != nil {
			return nil, err
		}
		if err := add(directory+"ami-publish-pipeline-stack.yml", AMIPublishPipelineStack(name, environment)); err != nil {
			return nil, err
		}
		if err := add(directory+"ssm-documents-stack.yml", SSMDocumentsStack(name, environment)); err != nil {
			return nil, err
		}
	}
	return files, nil
}

// Render は定義を YAML にする。先頭に生成物である旨の注意書きを付ける。
func Render(definition Map) ([]byte, error) {
	var buffer bytes.Buffer
	buffer.WriteString(generatedFileHeader)
	encoder := yaml.NewEncoder(&buffer)
	encoder.SetIndent(2)
	if err := encoder.Encode(definition); err != nil {
		return nil, err
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

// WriteAll は生成したファイルを出力先ディレクトリに書き出す。
func WriteAll(outputDirectory string, files []File) error {
	for _, file := range files {
		path := filepath.Join(outputDirectory, filepath.FromSlash(file.Path))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, file.Content, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// Differences は、出力先ディレクトリの内容と生成結果の違いを返す（--check 用）。
// 内容が違うファイル、まだ生成されていないファイル、生成対象にない古いファイルを列挙する。
func Differences(outputDirectory string, files []File) ([]string, error) {
	var differences []string
	expected := map[string]bool{}
	for _, file := range files {
		expected[file.Path] = true
		current, err := os.ReadFile(filepath.Join(outputDirectory, filepath.FromSlash(file.Path)))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			differences = append(differences, "未生成: "+file.Path)
		case err != nil:
			return nil, err
		case !bytes.Equal(current, file.Content):
			differences = append(differences, "内容が異なる: "+file.Path)
		}
	}

	stale, err := staleFiles(outputDirectory, expected)
	if err != nil {
		return nil, err
	}
	for _, path := range stale {
		differences = append(differences, "生成対象にない: "+path)
	}
	return differences, nil
}

// StaleFiles は、出力先ディレクトリにあるが生成対象にないファイルを返す（環境を削除した後の残骸など）。
func StaleFiles(outputDirectory string, files []File) ([]string, error) {
	expected := map[string]bool{}
	for _, file := range files {
		expected[file.Path] = true
	}
	return staleFiles(outputDirectory, expected)
}

func staleFiles(outputDirectory string, expected map[string]bool) ([]string, error) {
	var stale []string
	err := filepath.WalkDir(outputDirectory, func(path string, entry fs.DirEntry, err error) error {
		if errors.Is(err, fs.ErrNotExist) && path == outputDirectory {
			return filepath.SkipDir
		}
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".yml") {
			return nil
		}
		relative, err := filepath.Rel(outputDirectory, path)
		if err != nil {
			return err
		}
		if !expected[filepath.ToSlash(relative)] {
			stale = append(stale, filepath.ToSlash(relative))
		}
		return nil
	})
	sort.Strings(stale)
	return stale, err
}

func readUserData(repositoryRoot, path string) (string, error) {
	if path == "" {
		return "", nil
	}
	content, err := os.ReadFile(filepath.Join(repositoryRoot, filepath.FromSlash(path)))
	if err != nil {
		return "", fmt.Errorf("launch_template.user_data_file を読めない: %w", err)
	}
	return string(content), nil
}
