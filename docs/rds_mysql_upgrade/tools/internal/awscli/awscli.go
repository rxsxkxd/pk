// Package awscli は AWS CLI を exec する（tools/ 共通）。
//
// **SDK は使わず AWS CLI を呼ぶ。**シェル版と同じコマンドを同じ引数で叩くため、
// 権限・プロファイル・リージョンの解決がシェル版・CI と同じになる。
// 変更操作を行う呼び出しには、呼び出し側で `// [変更]` のコメントを付ける。
package awscli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Client は --region / --profile を前置して aws を呼ぶ。どちらも空なら付けない
// （AWS CLI の設定に委ねる）。
type Client struct {
	Region  string
	Profile string
}

// Error は aws の失敗である。Stderr に AWS CLI のメッセージを持つ。
type Error struct {
	Arguments []string
	ExitCode  int
	Stderr    string
}

func (e *Error) Error() string {
	return fmt.Sprintf("aws %s が失敗した（終了コード %d）: %s", strings.Join(e.Arguments, " "), e.ExitCode, e.Stderr)
}

// NotFound は、AWS CLI のエラーが「対象が存在しない」ことを示すかを返す
// （DBInstanceNotFound / DBSnapshotNotFound など）。権限不足などと区別するために使う。
func NotFound(err error) bool {
	failure, ok := err.(*Error)
	return ok && strings.Contains(failure.Stderr, "NotFound")
}

func (c Client) base() []string {
	var args []string
	if c.Region != "" {
		args = append(args, "--region", c.Region)
	}
	if c.Profile != "" {
		args = append(args, "--profile", c.Profile)
	}
	return args
}

// Run は aws を実行して標準出力を返す。
func (c Client) Run(arguments ...string) ([]byte, error) {
	command := exec.Command("aws", append(c.base(), arguments...)...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		exitCode := -1
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		}
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, &Error{Arguments: arguments, ExitCode: exitCode, Stderr: message}
	}
	return stdout.Bytes(), nil
}

// Text は `--output text` で取り、前後の空白を落として返す。
func (c Client) Text(arguments ...string) (string, error) {
	out, err := c.Run(append(arguments, "--output", "text")...)
	return strings.TrimSpace(string(out)), err
}

// JSON は `--output json` で取り、saveTo が空でなければ**生の応答**をそのまま保存し、
// destination が nil でなければ解析結果を入れる。
func (c Client) JSON(saveTo string, destination any, arguments ...string) error {
	out, err := c.Run(append(arguments, "--output", "json")...)
	if err != nil {
		return err
	}
	if saveTo != "" {
		if err := os.WriteFile(saveTo, out, 0o644); err != nil {
			return fmt.Errorf("%s: 書き込めない: %w", saveTo, err)
		}
	}
	if destination != nil {
		if err := json.Unmarshal(out, destination); err != nil {
			return fmt.Errorf("aws %s の応答を解析できない: %w", strings.Join(arguments, " "), err)
		}
	}
	return nil
}
