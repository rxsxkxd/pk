package handler

import (
	"context"

	"ticketqr/internal/apperr"
)

// Route keys exactly as configured on API Gateway HTTP API. The local server registers the same strings.
const (
	RouteIssueInline = "POST /v1/tickets/qr-inline"
	RouteIssue       = "POST /v1/tickets"
	RouteGetView     = "GET /v1/tickets/{ticketCode}/view"
	RouteGetQR       = "GET /v1/tickets/{ticketCode}/qr"
)

var RouteKeys = []string{RouteIssueInline, RouteIssue, RouteGetView, RouteGetQR}

// Route dispatches on the event's routeKey, so one deployment package serves every endpoint
// whether API Gateway points all routes at one function or at several.
func (h *Handlers) Route(ctx context.Context, req Request) (Response, error) {
	switch req.RouteKey {
	case RouteIssueInline:
		return h.IssueInline(ctx, req)
	case RouteIssue:
		return h.Issue(ctx, req)
	case RouteGetView:
		return h.GetView(ctx, req)
	case RouteGetQR:
		return h.GetQR(ctx, req)
	default:
		return h.run(ctx, req, "unknown", h.jsonError, func() (Response, error) {
			return Response{}, apperr.NotFound()
		})
	}
}
