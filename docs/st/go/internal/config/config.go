// Package config reads runtime settings: environment variables (config.go) and secrets from Parameter
// Store (secret.go). Clean architecture: a framework / driver used only by the wiring in cmd/ticketqr.
package config

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	PublicBaseURL string // absolute, no trailing slash
	PublicOrigin  string // scheme://host[:port], for CSP

	AnalyzerMode    string        // mock | http
	AnalyzerURL     string        // http only
	AnalyzerTimeout time.Duration // http only, per attempt
}

const (
	defaultAnalyzerTimeout = 5 * time.Second
)

func Load() (Config, error) {
	base := strings.TrimRight(os.Getenv("PUBLIC_BASE_URL"), "/")
	u, err := url.Parse(base)
	if base == "" || err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return Config{}, fmt.Errorf("PUBLIC_BASE_URL must be an absolute http(s) URL, got %q", base)
	}

	cfg := Config{
		PublicBaseURL:   base,
		PublicOrigin:    u.Scheme + "://" + u.Host,
		AnalyzerMode:    os.Getenv("ANALYZER_MODE"),
		AnalyzerTimeout: defaultAnalyzerTimeout,
	}
	if cfg.AnalyzerMode == "http" {
		cfg.AnalyzerURL = os.Getenv("ANALYZER_URL")
		if a, err := url.Parse(cfg.AnalyzerURL); cfg.AnalyzerURL == "" || err != nil ||
			(a.Scheme != "https" && a.Scheme != "http") || a.Host == "" {
			return Config{}, fmt.Errorf("ANALYZER_URL must be an absolute http(s) URL, got %q", cfg.AnalyzerURL)
		}
		if v := os.Getenv("ANALYZER_TIMEOUT_MS"); v != "" {
			ms, err := strconv.Atoi(v)
			if err != nil || ms < 1 {
				return Config{}, fmt.Errorf("ANALYZER_TIMEOUT_MS must be a positive integer, got %q", v)
			}
			cfg.AnalyzerTimeout = time.Duration(ms) * time.Millisecond
		}
	}
	return cfg, nil
}
