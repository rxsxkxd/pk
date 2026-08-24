package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"ticketqr/internal/analyzer"
)

func TestRoute(t *testing.T) {
	h := newHandlers(t, analyzer.AlwaysPass{})
	code := "202610011943003f2b9c1e8a4d4f6b8e0c7a1d2b3c4d5eTQR"
	signed := signedGet(h, code, h.Signer.Sign(code))
	withKey := func(req Request, key string) Request { req.RouteKey = key; return req }

	tests := []struct {
		name        string
		req         Request
		status      int
		contentType string
	}{
		{"A", withKey(formRequest(t, "image", jpeg), RouteGrantInline), http.StatusCreated, "application/json"},
		{"B-1", withKey(formRequest(t, "image", jpeg), RouteGrant), http.StatusSeeOther, ""},
		{"B-3", withKey(signed, RouteGetView), http.StatusOK, "text/html"},
		{"B-2", withKey(signed, RouteGetQR), http.StatusOK, "image/png"},
		{"unknown", withKey(signed, "GET /v1/unknown"), http.StatusNotFound, "application/json"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res, err := h.Route(context.Background(), tt.req)
			if err != nil {
				t.Fatalf("Route returned Go error: %v", err)
			}
			if res.StatusCode != tt.status || !strings.HasPrefix(res.Headers["Content-Type"], tt.contentType) {
				t.Errorf("got %d %q, want %d %q", res.StatusCode, res.Headers["Content-Type"], tt.status, tt.contentType)
			}
		})
	}
}
