package config

import (
	"context"
	"testing"
	"time"
)

func TestAnalyzerSettings(t *testing.T) {
	t.Setenv("PUBLIC_BASE_URL", "https://api.example.com")

	t.Setenv("ANALYZER_MODE", "mock")
	if cfg, err := Load(); err != nil || cfg.AnalyzerURL != "" {
		t.Fatalf("mock: %+v, %v", cfg, err)
	}

	t.Setenv("ANALYZER_MODE", "http")
	t.Setenv("ANALYZER_URL", "")
	if _, err := Load(); err == nil {
		t.Error("http without ANALYZER_URL must fail")
	}

	t.Setenv("ANALYZER_URL", "https://stub.example.com/v1/analyze")
	cfg, err := Load()
	if err != nil || cfg.AnalyzerURL != "https://stub.example.com/v1/analyze" || cfg.AnalyzerTimeout != 5*time.Second {
		t.Fatalf("http defaults: %+v, %v", cfg, err)
	}

	t.Setenv("ANALYZER_TIMEOUT_MS", "1500")
	if cfg, err := Load(); err != nil || cfg.AnalyzerTimeout != 1500*time.Millisecond {
		t.Errorf("timeout: %+v, %v", cfg, err)
	}
	t.Setenv("ANALYZER_TIMEOUT_MS", "0")
	if _, err := Load(); err == nil {
		t.Error("ANALYZER_TIMEOUT_MS=0 must fail")
	}
}

func TestMaxImageBytes(t *testing.T) {
	t.Setenv("PUBLIC_BASE_URL", "https://api.example.com")
	t.Setenv("ANALYZER_MODE", "mock")

	t.Setenv("MAX_IMAGE_BYTES", "")
	if cfg, err := Load(); err != nil || cfg.MaxImageBytes != 0 {
		t.Errorf("unset: %+v, %v", cfg, err)
	}
	t.Setenv("MAX_IMAGE_BYTES", "1048576")
	if cfg, err := Load(); err != nil || cfg.MaxImageBytes != 1<<20 {
		t.Errorf("1MB: %+v, %v", cfg, err)
	}
	for _, v := range []string{"0", "-1", "4MB"} {
		t.Setenv("MAX_IMAGE_BYTES", v)
		if _, err := Load(); err == nil {
			t.Errorf("MAX_IMAGE_BYTES=%s must fail", v)
		}
	}
}

func TestLoadTicketCodeSuffix(t *testing.T) {
	t.Setenv("TICKET_CODE_SUFFIX_PARAMETER_NAME", "")
	t.Setenv("TICKET_CODE_SUFFIX", "TQR")
	if got, err := LoadTicketCodeSuffix(context.Background()); err != nil || got != "TQR" {
		t.Errorf("LoadTicketCodeSuffix = %q, %v; want TQR (plain value: not a secret)", got, err)
	}
	t.Setenv("TICKET_CODE_SUFFIX", "")
	if _, err := LoadTicketCodeSuffix(context.Background()); err == nil {
		t.Error("want an error when neither TICKET_CODE_SUFFIX_PARAMETER_NAME nor TICKET_CODE_SUFFIX is set")
	}
}
