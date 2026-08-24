// Package localhttp はローカル開発用に Lambda ハンドラを net/http の背後で動かす。
// 各リクエストは、一致する routeKey を持つ API Gateway HTTP API(v2)イベントに変換される。クリーン
// アーキテクチャ: ローカルサーバと E2E ゲートウェイ(cmd/*)が使うドライバで、デプロイはしない。
package localhttp

import (
	"context"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/google/uuid"
)

type HandlerFunc func(context.Context, events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error)

// Adapt は routeKey に対して fn を提供する。API Gateway のルートキー("GET /v1/x/{id}")はそのまま ServeMux の
// パターンとして有効なので、mux.Handle(routeKey, Adapt(routeKey, fn)) で登録する。
func Adapt(routeKey string, fn HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		req := events.APIGatewayV2HTTPRequest{
			Version:               "2.0",
			RouteKey:              routeKey,
			RawPath:               r.URL.Path,
			RawQueryString:        r.URL.RawQuery,
			Headers:               map[string]string{},
			QueryStringParameters: map[string]string{},
			PathParameters:        map[string]string{},
			Body:                  base64.StdEncoding.EncodeToString(body),
			IsBase64Encoded:       true,
		}
		req.RequestContext.RequestID = uuid.NewString()
		req.RequestContext.RouteKey = routeKey
		req.RequestContext.Stage = "$default"
		req.RequestContext.DomainName = r.Host
		req.RequestContext.TimeEpoch = time.Now().UnixMilli()
		req.RequestContext.HTTP.Protocol = r.Proto
		req.RequestContext.HTTP.SourceIP, _, _ = net.SplitHostPort(r.RemoteAddr)
		req.RequestContext.HTTP.UserAgent = r.UserAgent()
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
