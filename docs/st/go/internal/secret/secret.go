// Package secret loads the signing salts.
package secret

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
		return fromParameterStore(ctx, name)
	}
	if os.Getenv("APP_ENV") == "local" {
		if v := os.Getenv("SIGNING_SALT"); v != "" {
			return Salts{Current: v}, nil
		}
	}
	return Salts{}, errors.New("SIGNING_SALT_PARAMETER_NAME is not set")
}

func fromParameterStore(ctx context.Context, name string) (Salts, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return Salts{}, fmt.Errorf("load aws config: %w", err)
	}
	out, err := ssm.NewFromConfig(cfg).GetParameter(ctx, &ssm.GetParameterInput{
		Name:           aws.String(name),
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return Salts{}, fmt.Errorf("get signing salt: %w", err)
	}
	var s Salts
	if err := json.Unmarshal([]byte(aws.ToString(out.Parameter.Value)), &s); err != nil {
		return Salts{}, fmt.Errorf("parse signing salt parameter: %w", err)
	}
	return s, nil
}
