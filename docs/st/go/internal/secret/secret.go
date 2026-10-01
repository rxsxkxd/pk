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
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

type Salts struct {
	Current  string `json:"current"`
	Previous string `json:"previous"`
}

// LoadSalts reads the secret named by SIGNING_SALT_SECRET_ID ({"current": "...", "previous": "..."}).
// For local development only (APP_ENV=local), SIGNING_SALT may hold the salt in plain text.
func LoadSalts(ctx context.Context) (Salts, error) {
	if id := os.Getenv("SIGNING_SALT_SECRET_ID"); id != "" {
		return fromSecretsManager(ctx, id)
	}
	if os.Getenv("APP_ENV") == "local" {
		if v := os.Getenv("SIGNING_SALT"); v != "" {
			return Salts{Current: v}, nil
		}
	}
	return Salts{}, errors.New("SIGNING_SALT_SECRET_ID is not set")
}

func fromSecretsManager(ctx context.Context, id string) (Salts, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return Salts{}, fmt.Errorf("load aws config: %w", err)
	}
	out, err := secretsmanager.NewFromConfig(cfg).GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(id),
	})
	if err != nil {
		return Salts{}, fmt.Errorf("get signing salt: %w", err)
	}
	var s Salts
	if err := json.Unmarshal([]byte(aws.ToString(out.SecretString)), &s); err != nil {
		return Salts{}, fmt.Errorf("parse signing salt secret: %w", err)
	}
	return s, nil
}
