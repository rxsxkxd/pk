// Package config は実行時の設定を読み込む: 環境変数(config.go)と Parameter Store のシークレット
// (secret.go)。クリーンアーキテクチャ: cmd/ticketqr の配線からのみ使われるフレームワーク / ドライバ。
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
	PublicBaseURL string // 絶対 URL、末尾スラッシュなし
	PublicOrigin  string // scheme://host[:port]、CSP 用

	AnalyzerMode    string        // mock | http
	AnalyzerURL     string        // http のみ
	AnalyzerTimeout time.Duration // http のみ、1 回の試行あたり

	MaxImageBytes int // MAX_IMAGE_BYTES。0 = 未設定(ランタイムの上限 imageinput.MaxBytes)
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
	if v := os.Getenv("MAX_IMAGE_BYTES"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return Config{}, fmt.Errorf("MAX_IMAGE_BYTES must be a positive integer, got %q", v)
		}
		cfg.MaxImageBytes = n
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
