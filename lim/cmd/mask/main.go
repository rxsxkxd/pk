// Command mask は S3 上の画像にガウスぼかしを適用して S3 に保存する Lambda。
//
// 起動方法は 2 つ。
//
//	S3 の ObjectCreated 通知
//	キーの変数部分を渡すリクエスト: {"x":"...","y":"...","z":"...","n":"..."}
//
// どちらもペイロードの形で判別する（internal/handler.Handle）。
package main

import (
	"context"
	"log/slog"
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"github.com/rxsxkxd/lim/internal/config"
	"github.com/rxsxkxd/lim/internal/handler"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel()}))
	slog.SetDefault(log)

	cfg, err := config.Load()
	if err != nil {
		log.Error("invalid configuration", slog.Any("error", err))
		os.Exit(1)
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Error("cannot load aws config", slog.Any("error", err))
		os.Exit(1)
	}

	h := &handler.Handler{
		S3:  s3.NewFromConfig(awsCfg),
		Cfg: cfg,
		Log: log,
	}
	lambda.Start(h.Handle)
}

func logLevel() slog.Level {
	var l slog.Level
	if err := l.UnmarshalText([]byte(os.Getenv("LOG_LEVEL"))); err != nil {
		return slog.LevelInfo
	}
	return l
}
