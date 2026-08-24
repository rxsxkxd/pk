package main

// 配線(クリーンアーキテクチャのコンポジションルート): 設定とシークレットを読み込み、検証器(package analyzer)を選び、
// package ticket を中心に HTTP ハンドラを組み立てる。

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"ticketqr/internal/analyzer"
	"ticketqr/internal/config"
	"ticketqr/internal/httpapi"
	"ticketqr/internal/imageinput"
	"ticketqr/internal/signer"
	"ticketqr/internal/ticket"
	"ticketqr/internal/view"
)

// newHandlers は環境変数(Lambda 上では Parameter Store も)からハンドラを組み立てる。
func newHandlers(ctx context.Context) (*httpapi.Handlers, error) {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	// ランタイムの上限(Lambda のリクエストは 6MB、API Gateway が base64 化する)は設定では引き上げられない。
	if cfg.MaxImageBytes > imageinput.MaxBytes {
		return nil, fmt.Errorf("MAX_IMAGE_BYTES must be %d or less, got %d", imageinput.MaxBytes, cfg.MaxImageBytes)
	}
	var httpCfg analyzer.HTTPConfig
	if cfg.AnalyzerMode == "http" {
		key, err := config.LoadAnalyzerAPIKey(ctx)
		if err != nil {
			return nil, err
		}
		httpCfg = analyzer.HTTPConfig{URL: cfg.AnalyzerURL, APIKey: key, Timeout: cfg.AnalyzerTimeout, Logger: logger}
	}
	an, err := analyzer.New(cfg.AnalyzerMode, httpCfg)
	if err != nil {
		return nil, err
	}
	salts, err := config.LoadSalts(ctx)
	if err != nil {
		return nil, err
	}
	sg, err := signer.New(salts.Current, salts.Previous)
	if err != nil {
		return nil, err
	}
	vw, err := view.New()
	if err != nil {
		return nil, err
	}
	suffix, err := config.LoadTicketCodeSuffix(ctx)
	if err != nil {
		return nil, err
	}
	generator, err := ticket.NewGenerator(suffix)
	if err != nil {
		return nil, err
	}

	return &httpapi.Handlers{
		PublicBaseURL: cfg.PublicBaseURL,
		PublicOrigin:  cfg.PublicOrigin,
		Ports: ticket.Ports{
			Verifier:  an,
			Generator: generator,
			Logger:    logger,
		},
		Signer:        sg,
		View:          vw,
		Logger:        logger,
		MaxImageBytes: cfg.MaxImageBytes,
	}, nil
}

// mustNewHandlers は初期化に失敗したら終了する: 初期化できない Lambda は init フェーズで失敗させるべきため。
func mustNewHandlers() *httpapi.Handlers {
	h, err := newHandlers(context.Background())
	if err != nil {
		slog.Error("initialization failed", "error", err)
		os.Exit(1)
	}
	return h
}
