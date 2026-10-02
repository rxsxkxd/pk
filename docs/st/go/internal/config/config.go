// Package config reads runtime settings from environment variables.
package config

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	PublicBaseURL string // absolute, no trailing slash
	PublicOrigin  string // scheme://host[:port], for CSP
	SuffixLength  int
	AnalyzerMode  string
}

const defaultSuffixLength = 8

func Load() (Config, error) {
	base := strings.TrimRight(os.Getenv("PUBLIC_BASE_URL"), "/")
	u, err := url.Parse(base)
	if base == "" || err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return Config{}, fmt.Errorf("PUBLIC_BASE_URL must be an absolute http(s) URL, got %q", base)
	}

	suffixLength := defaultSuffixLength
	if v := os.Getenv("TICKET_SUFFIX_LENGTH"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 32 {
			return Config{}, fmt.Errorf("TICKET_SUFFIX_LENGTH must be 1-32, got %q", v)
		}
		suffixLength = n
	}

	return Config{
		PublicBaseURL: base,
		PublicOrigin:  u.Scheme + "://" + u.Host,
		SuffixLength:  suffixLength,
		AnalyzerMode:  os.Getenv("ANALYZER_MODE"),
	}, nil
}
