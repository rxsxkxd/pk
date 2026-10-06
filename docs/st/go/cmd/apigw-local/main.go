// Command apigw-local plays the role of API Gateway (HTTP API) in the E2E environment (E2E.md 2.3): it
// turns HTTP requests into payload v2 events for the routes of api.yaml, invokes the function running on
// the Lambda Runtime Interface Emulator (RIE) and applies the CORS configuration. Not deployed.
//
// Environment:
//
//	LISTEN_ADDR         default :3000
//	RIE_URL             default http://127.0.0.1:8080/2015-03-31/functions/function/invocations
//	CORS_ALLOW_ORIGINS  comma-separated origins allowed by CORS (AllowOrigins of the HTTP API)
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"ticketqr/internal/httpapi"
	"ticketqr/internal/localhttp"
)

// Same routes as infra/cloudformation/api.yaml (one function serves them all, as the zip does).
var routes = []string{httpapi.RouteGrantInline, httpapi.RouteGrant, httpapi.RouteGetView, httpapi.RouteGetQR}

func main() {
	addr := env("LISTEN_ADDR", ":3000")
	invoke := rieInvoker(env("RIE_URL", "http://127.0.0.1:8080/2015-03-31/functions/function/invocations"))
	origins := splitList(os.Getenv("CORS_ALLOW_ORIGINS"))

	mux := http.NewServeMux()
	for _, rk := range routes {
		mux.Handle(rk, localhttp.Adapt(rk, invoke))
	}
	// API Gateway answers unmatched routes itself.
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusNotFound, `{"message":"Not Found"}`)
	})

	slog.Info("apigw-local listening", "addr", addr, "corsAllowOrigins", origins)
	if err := http.ListenAndServe(addr, cors(origins, mux)); err != nil {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

// rieInvoker sends the event to the RIE and decodes the function's response. A function error (the RIE
// answers with errorMessage/errorType) becomes API Gateway's 500, as in production.
func rieInvoker(url string) localhttp.HandlerFunc {
	client := &http.Client{Timeout: 30 * time.Second}
	return func(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
		internalError := events.APIGatewayV2HTTPResponse{
			StatusCode: http.StatusInternalServerError,
			Headers:    map[string]string{"Content-Type": "application/json"},
			Body:       `{"message":"Internal Server Error"}`,
		}
		event, err := json.Marshal(req)
		if err != nil {
			return internalError, nil
		}
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(event))
		if err != nil {
			return internalError, nil
		}
		resp, err := client.Do(httpReq)
		if err != nil {
			slog.Error("invoke failed", "error", err)
			return internalError, nil
		}
		defer resp.Body.Close()

		var out struct {
			events.APIGatewayV2HTTPResponse
			ErrorMessage string `json:"errorMessage"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.StatusCode == 0 {
			slog.Error("function error", "decodeError", err, "errorMessage", out.ErrorMessage)
			return internalError, nil
		}
		return out.APIGatewayV2HTTPResponse, nil
	}
}

// cors applies the HTTP API's CORS configuration: preflight requests from allowed origins are answered by
// the gateway, and responses to allowed origins get Access-Control-Allow-Origin. Requests from other
// origins are still forwarded (CORS only controls what the browser lets the page read).
func cors(origins []string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := origin != "" && slices.Contains(origins, origin)
		if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
			if allowed {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Add("Vary", "Origin")
				w.Header().Set("Access-Control-Allow-Methods", "GET,POST")
				w.Header().Set("Access-Control-Max-Age", "300")
			}
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(&corsWriter{ResponseWriter: w, origin: origin, allowed: allowed}, r)
	})
}

// corsWriter adds the CORS headers when the status is written, after the function's own headers (which
// may set Vary as well).
type corsWriter struct {
	http.ResponseWriter
	origin  string
	allowed bool
}

func (w *corsWriter) WriteHeader(status int) {
	if w.allowed {
		w.Header().Set("Access-Control-Allow-Origin", w.origin)
		w.Header().Add("Vary", "Origin")
	}
	w.ResponseWriter.WriteHeader(status)
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	fmt.Fprint(w, body)
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func splitList(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}
