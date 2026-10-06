package httpapi

import (
	"context"
)

// Route keys exactly as configured on API Gateway HTTP API. The local server registers the same strings.
const (
	RouteGrantInline = "POST /v1/tickets/qr-inline"
	RouteGrant       = "POST /v1/tickets"
	RouteGetView     = "GET /v1/tickets/{ticketCode}/view"
	RouteGetQR       = "GET /v1/tickets/{ticketCode}/qr"
)

var RouteKeys = []string{RouteGrantInline, RouteGrant, RouteGetView, RouteGetQR}

// Route dispatches on the event's routeKey, so one deployment package serves every endpoint
// whether API Gateway points all routes at one function or at several.
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
