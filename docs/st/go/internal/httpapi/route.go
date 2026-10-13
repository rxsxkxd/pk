package httpapi

import (
	"context"
)

// API Gateway HTTP API に設定したとおりのルートキー。ローカルサーバも同じ文字列を登録する。
const (
	RouteGrantInline = "POST /v1/tickets/qr-inline"
	RouteGrant       = "POST /v1/tickets"
	RouteGetView     = "GET /v1/tickets/{ticketCode}/view"
	RouteGetQR       = "GET /v1/tickets/{ticketCode}/qr"
)

var RouteKeys = []string{RouteGrantInline, RouteGrant, RouteGetView, RouteGetQR}

// Route はイベントの routeKey で振り分けるので、API Gateway がすべてのルートを 1 つの関数に向けても
// 複数の関数に向けても、1 つのデプロイパッケージですべてのエンドポイントを処理できる。
func (h *Handlers) Route(ctx context.Context, req Request) (Response, error) {
	switch req.RouteKey {
	case RouteGrantInline:
		return h.GrantInline(ctx, req)
	case RouteGrant:
		return h.Grant(ctx, req)
	case RouteGetView:
		return h.GetView(ctx, req)
	case RouteGetQR:
		return h.GetQR(ctx, req)
	default:
		return h.run(ctx, req, "unknown", h.jsonError, func() (Response, error) {
			return Response{}, notFound()
		})
	}
}
