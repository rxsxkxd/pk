package config

// Values from Parameter Store: the signing salts and the analyzer API key (SecureString), and the ticket
// code's fixed suffix (String).

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

// LoadSalts reads the SecureString parameter named by SIGNING_SALT_PARAMETER_NAME from Parameter Store
// ({"current": "...", "previous": "..."}). For local development only (APP_ENV=local), SIGNING_SALT may
// hold the salt in plain text.
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

// LoadTicketCodeSuffix reads the fixed suffix of ticket codes (DESIGN.md 4) from the String parameter named
// by TICKET_CODE_SUFFIX_PARAMETER_NAME. Not a secret, so TICKET_CODE_SUFFIX may also hold it directly (local
// runs and E2E). The value is checked by ticket.NewGenerator.
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

// LoadAnalyzerAPIKey reads the image analysis server's API key from the SecureString parameter named by
// ANALYZER_API_KEY_PARAMETER_NAME. For local development only (APP_ENV=local), ANALYZER_API_KEY may hold
// it in plain text. The key is optional: with neither set it returns "" and requests carry no x-api-key
// (e.g. a server that only admits the Lambda's security group in the VPC).
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

// getParameter reads and decrypts one Parameter Store value.
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
