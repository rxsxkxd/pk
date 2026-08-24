// Command apigw-local は E2E 環境(E2E.md 2.3)で API Gateway(HTTP API)の役割を担う: HTTP リクエストを
// api.yaml のルートに対応する payload v2 イベントに変換し、Lambda Runtime Interface Emulator(RIE)上で動く
// 関数を呼び出し、CORS 設定を適用する。デプロイはしない。
//
// 環境変数:
//
//	LISTEN_ADDR         デフォルト :3000
//	RIE_URL             デフォルト http://127.0.0.1:8080/2015-03-31/functions/function/invocations
//	CORS_ALLOW_ORIGINS  CORS で許可するオリジンのカンマ区切り(HTTP API の AllowOrigins)
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

// infra/cloudformation/api.yaml と同じルート(zip と同様に、1 つの関数ですべてを処理する)。
var routes = []string{httpapi.RouteGrantInline, httpapi.RouteGrant, httpapi.RouteGetView, httpapi.RouteGetQR}

func main() {
	addr := env("LISTEN_ADDR", ":3000")
	invoke := rieInvoker(env("RIE_URL", "http://127.0.0.1:8080/2015-03-31/functions/function/invocations"))
	origins := splitList(os.Getenv("CORS_ALLOW_ORIGINS"))

	mux := http.NewServeMux()
	for _, rk := range routes {
		mux.Handle(rk, localhttp.Adapt(rk, invoke))
	}
	// マッチしないルートには API Gateway 自身が応答する。
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusNotFound, `{"message":"Not Found"}`)
	})

	slog.Info("apigw-local listening", "addr", addr, "corsAllowOrigins", origins)
	if err := http.ListenAndServe(addr, cors(origins, mux)); err != nil {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

// rieInvoker はイベントを RIE に送り、関数のレスポンスをデコードする。関数エラー(RIE が errorMessage/errorType で
// 応答する)は本番と同様に API Gateway の 500 になる。
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

// cors は HTTP API の CORS 設定を適用する: 許可されたオリジンからのプリフライトリクエストにはゲートウェイが応答し、
// 許可されたオリジンへのレスポンスには Access-Control-Allow-Origin を付ける。それ以外のオリジンからの
// リクエストも転送はする(CORS はブラウザがページに何を読ませるかを制御するだけ)。
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

// corsWriter はステータス書き込み時に、関数自身のヘッダ(Vary を設定することもある)の後で CORS ヘッダを追加する。
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
