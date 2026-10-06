package main

// The handler: a fixed QR code for https://example.com. It is deployed separately from the ticket
// endpoints and needs no configuration or secrets.

import (
	"context"
	"encoding/base64"
	"log/slog"
	"net/http"

	"github.com/aws/aws-lambda-go/events"

	"ticketqr/internal/qr"
)

const (
	routeKey = "GET /v1/example/qr"
	// Includes the scheme so QR readers open it as a link instead of plain text.
	content = "https://example.com"
)

func handle(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	png, err := qr.PNG(content)
	if err != nil {
		slog.ErrorContext(ctx, "render qr failed", "requestId", req.RequestContext.RequestID, "error", err)
		return events.APIGatewayV2HTTPResponse{
			StatusCode: http.StatusInternalServerError,
			Headers:    headers("application/json; charset=utf-8"),
			Body:       `{"error":{"code":"INTERNAL_ERROR","message":"internal error"}}`,
		}, nil
	}
	return events.APIGatewayV2HTTPResponse{
		StatusCode:      http.StatusOK,
		Headers:         headers("image/png"),
		Body:            base64.StdEncoding.EncodeToString(png),
		IsBase64Encoded: true,
	}, nil
}

func headers(contentType string) map[string]string {
	return map[string]string{
		"Content-Type":           contentType,
		"Cache-Control":          "no-store",
		"X-Content-Type-Options": "nosniff",
	}
}
