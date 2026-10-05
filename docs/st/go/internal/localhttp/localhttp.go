// Package localhttp runs Lambda handlers behind net/http for local development.
// Each request becomes an API Gateway HTTP API (v2) event carrying the matching routeKey.
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

// Adapt serves fn for routeKey. API Gateway route keys ("GET /v1/x/{id}") are valid ServeMux
// patterns, so register the handler with mux.Handle(routeKey, Adapt(routeKey, fn)).
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
