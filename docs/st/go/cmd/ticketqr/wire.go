package main

// Wiring (clean architecture: the composition root): reads the configuration and secrets, picks the
// verifier (package analyzer), and assembles the HTTP handlers around package ticket.

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

// newHandlers builds the handlers from the environment (and Parameter Store on Lambda).
func newHandlers(ctx context.Context) (*httpapi.Handlers, error) {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	// The runtime ceiling (Lambda's 6MB request, base64 by API Gateway) cannot be raised by configuration.
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

// mustNewHandlers exits when initialization fails: a Lambda that cannot initialize should fail its init phase.
func mustNewHandlers() *httpapi.Handlers {
	h, err := newHandlers(context.Background())
	if err != nil {
		slog.Error("initialization failed", "error", err)
		os.Exit(1)
	}
	return h
}
