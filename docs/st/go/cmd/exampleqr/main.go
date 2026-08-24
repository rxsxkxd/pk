// Command exampleqr は example.com の QR エンドポイントを提供する。cmd/ticketqr とは別のデプロイパッケージで、
// Lambda 上では API Gateway のイベントを処理し、それ以外ではローカルサーバを起動する。
package main

import (
	"flag"
	"log"
	"log/slog"
	"net/http"
	"os"

	"github.com/aws/aws-lambda-go/lambda"

	"ticketqr/internal/localhttp"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if os.Getenv("AWS_LAMBDA_RUNTIME_API") != "" {
		lambda.Start(handle)
		return
	}

	addr := flag.String("addr", ":8081", "listen address")
	flag.Parse()
	mux := http.NewServeMux()
	mux.Handle(routeKey, localhttp.Adapt(routeKey, handle))
	log.Printf("listening on %s (open http://localhost%s/v1/example/qr)", *addr, *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}
