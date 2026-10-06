// Package app wires configuration and dependencies into handlers.
package app

import (
	"context"
	"log/slog"
	"os"

	"ticketqr/internal/analyzer"
	"ticketqr/internal/config"
	"ticketqr/internal/handler"
	"ticketqr/internal/secret"
	"ticketqr/internal/signer"
	"ticketqr/internal/ticketcode"
	"ticketqr/internal/usecase"
	"ticketqr/internal/view"
)

func New(ctx context.Context) (*handler.Handlers, error) {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	var httpCfg analyzer.HTTPConfig
	if cfg.AnalyzerMode == "http" {
		key, err := secret.LoadAnalyzerAPIKey(ctx)
		if err != nil {
			return nil, err
		}
		httpCfg = analyzer.HTTPConfig{URL: cfg.AnalyzerURL, APIKey: key, Timeout: cfg.AnalyzerTimeout}
	}
	an, err := analyzer.New(cfg.AnalyzerMode, httpCfg)
	if err != nil {
		return nil, err
	}
	salts, err := secret.LoadSalts(ctx)
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

	return &handler.Handlers{
		PublicBaseURL: cfg.PublicBaseURL,
		PublicOrigin:  cfg.PublicOrigin,
		Issuer: &usecase.Issuer{
			Analyzer:  an,
			Generator: ticketcode.NewGenerator(cfg.SuffixLength),
			Logger:    logger,
		},
		Signer: sg,
		View:   vw,
		Logger: logger,
	}, nil
}

// MustNew is for main packages: a Lambda that cannot initialize should fail its init phase.
func MustNew() *handler.Handlers {
	h, err := New(context.Background())
	if err != nil {
		slog.Error("initialization failed", "error", err)
		os.Exit(1)
	}
	return h
}
