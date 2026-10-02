// Command exampleqr serves the example.com QR endpoint. It is a separate deployment package
// from cmd/ticketqr: on Lambda it handles API Gateway events, elsewhere it starts a local server.
package main

import (
	"flag"
	"log"
	"log/slog"
	"net/http"
	"os"

	"github.com/aws/aws-lambda-go/lambda"

	"ticketqr/go/internal/exampleqr"
	"ticketqr/go/internal/localhttp"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if os.Getenv("AWS_LAMBDA_RUNTIME_API") != "" {
		lambda.Start(exampleqr.Handle)
		return
	}

	addr := flag.String("addr", ":8081", "listen address")
	flag.Parse()
	mux := http.NewServeMux()
	mux.Handle(exampleqr.RouteKey, localhttp.Adapt(exampleqr.RouteKey, exampleqr.Handle))
	log.Printf("listening on %s (open http://localhost%s/v1/example/qr)", *addr, *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}
