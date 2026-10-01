// Command local serves the Lambda handlers over plain HTTP for local development.
//
// Each request is converted to an API Gateway HTTP API (v2) event, so the same handler code
// runs locally and on Lambda.
package main

import (
	"context"
	"encoding/base64"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/google/uuid"

	"ticketqr/go/internal/app"
	"ticketqr/go/internal/handler"
)

type lambdaFunc func(context.Context, handler.Request) (handler.Response, error)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	flag.Parse()

	setDefault("APP_ENV", "local")
	setDefault("PUBLIC_BASE_URL", "http://localhost"+*addr)
	setDefault("SIGNING_SALT", "local-dev-salt")
	setDefault("ANALYZER_MODE", "mock")

	h := app.MustNew()
	mux := http.NewServeMux()
	mux.Handle("POST /v1/tickets/qr-inline", adapt(h.IssueInline))
	mux.Handle("POST /v1/tickets", adapt(h.Issue))
	mux.Handle("GET /v1/tickets/{ticketCode}/view", adapt(h.GetView))
	mux.Handle("GET /v1/tickets/{ticketCode}/qr", adapt(h.GetQR))
	mux.HandleFunc("GET /{$}", uploadForm)

	log.Printf("listening on %s (open http://localhost%s/)", *addr, *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

func setDefault(key, value string) {
	if os.Getenv(key) == "" {
		os.Setenv(key, value)
	}
}

func adapt(fn lambdaFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		req := handler.Request{
			RawPath:               r.URL.Path,
			RawQueryString:        r.URL.RawQuery,
			Headers:               map[string]string{},
			QueryStringParameters: map[string]string{},
			PathParameters:        map[string]string{},
			Body:                  base64.StdEncoding.EncodeToString(body),
			IsBase64Encoded:       true,
		}
		req.RequestContext.RequestID = uuid.NewString()
		req.RequestContext.HTTP.Method = r.Method
		req.RequestContext.HTTP.Path = r.URL.Path
		for k, v := range r.Header {
			req.Headers[strings.ToLower(k)] = strings.Join(v, ",")
		}
		for k, v := range r.URL.Query() {
			req.QueryStringParameters[k] = strings.Join(v, ",")
		}
		if code := r.PathValue("ticketCode"); code != "" {
			req.PathParameters["ticketCode"] = code
		}

		res, err := fn(r.Context(), req)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		for k, v := range res.Headers {
			w.Header().Set(k, v)
		}
		out := []byte(res.Body)
		if res.IsBase64Encoded {
			if out, err = base64.StdEncoding.DecodeString(res.Body); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
		}
		w.WriteHeader(res.StatusCode)
		w.Write(out)
	})
}

// uploadForm stands in for the client page that submits pattern B-1. It exists only locally.
func uploadForm(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, `<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>ローカル動作確認</title></head>
<body>
  <h1>パターンB-1 動作確認</h1>
  <form method="post" action="/v1/tickets" enctype="multipart/form-data">
    <input type="file" name="image" accept="image/jpeg,image/png" required>
    <button type="submit">発行</button>
  </form>
</body>
</html>
`)
}
