package config

// Parameter Store の値: 署名用ソルトと解析サーバの API キー(SecureString)、およびチケット
// コードの固定サフィックス(String)。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

type Salts struct {
	Current  string `json:"current"`
	Previous string `json:"previous"`
}

// LoadSalts は SIGNING_SALT_PARAMETER_NAME で指定された SecureString パラメータを Parameter Store から読み込む
// ({"current": "...", "previous": "..."})。ローカル開発時のみ(APP_ENV=local)、SIGNING_SALT に
// ソルトを平文で持たせてもよい。
func LoadSalts(ctx context.Context) (Salts, error) {
	if name := os.Getenv("SIGNING_SALT_PARAMETER_NAME"); name != "" {
		value, err := getParameter(ctx, name)
		if err != nil {
			return Salts{}, fmt.Errorf("get signing salt: %w", err)
		}
		var s Salts
		if err := json.Unmarshal([]byte(value), &s); err != nil {
			return Salts{}, fmt.Errorf("parse signing salt parameter: %w", err)
		}
		return s, nil
	}
	if os.Getenv("APP_ENV") == "local" {
		if v := os.Getenv("SIGNING_SALT"); v != "" {
			return Salts{Current: v}, nil
		}
	}
	return Salts{}, errors.New("SIGNING_SALT_PARAMETER_NAME is not set")
}

// LoadTicketCodeSuffix は TICKET_CODE_SUFFIX_PARAMETER_NAME で指定された String パラメータから
// チケットコードの固定サフィックス(DESIGN.md 4)を読み込む。シークレットではないので、TICKET_CODE_SUFFIX に
// 直接持たせてもよい(ローカル実行と E2E)。値は ticket.NewGenerator が検査する。
func LoadTicketCodeSuffix(ctx context.Context) (string, error) {
	if name := os.Getenv("TICKET_CODE_SUFFIX_PARAMETER_NAME"); name != "" {
		value, err := getParameter(ctx, name)
		if err != nil {
			return "", fmt.Errorf("get ticket code suffix: %w", err)
		}
		return value, nil
	}
	if v := os.Getenv("TICKET_CODE_SUFFIX"); v != "" {
		return v, nil
	}
	return "", errors.New("TICKET_CODE_SUFFIX_PARAMETER_NAME is not set")
}

// LoadAnalyzerAPIKey は ANALYZER_API_KEY_PARAMETER_NAME で指定された SecureString パラメータから画像解析サーバの
// API キーを読み込む。ローカル開発時のみ(APP_ENV=local)、ANALYZER_API_KEY に平文で持たせてもよい。
// キーは任意: どちらも設定されていなければ "" を返し、リクエストに x-api-key は付かない
// (例: VPC 内で Lambda のセキュリティグループだけを受け入れるサーバ)。
func LoadAnalyzerAPIKey(ctx context.Context) (string, error) {
	if name := os.Getenv("ANALYZER_API_KEY_PARAMETER_NAME"); name != "" {
		key, err := getParameter(ctx, name)
		if err != nil {
			return "", fmt.Errorf("get analyzer api key: %w", err)
		}
		return key, nil
	}
	if os.Getenv("APP_ENV") == "local" {
		if v := os.Getenv("ANALYZER_API_KEY"); v != "" {
			return v, nil
		}
	}
	return "", nil
}

// getParameter は Parameter Store の値を 1 つ読み込んで復号する。
func getParameter(ctx context.Context, name string) (string, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return "", fmt.Errorf("load aws config: %w", err)
	}
	out, err := ssm.NewFromConfig(cfg).GetParameter(ctx, &ssm.GetParameterInput{
		Name:           aws.String(name),
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return "", err
	}
	if v := aws.ToString(out.Parameter.Value); v != "" {
		return v, nil
	}
	return "", fmt.Errorf("parameter %s is empty", name)
}
