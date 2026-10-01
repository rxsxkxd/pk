// Package app wires configuration and dependencies into handlers.
package app

import (
	"context"
	"log/slog"
	"os"

	"ticketqr/go/internal/analyzer"
	"ticketqr/go/internal/config"
	"ticketqr/go/internal/handler"
	"ticketqr/go/internal/secret"
	"ticketqr/go/internal/signer"
	"ticketqr/go/internal/ticketcode"
	"ticketqr/go/internal/usecase"
	"ticketqr/go/internal/view"
)

func New(ctx context.Context) (*handler.Handlers, error) {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	an, err := analyzer.New(cfg.AnalyzerMode)
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
