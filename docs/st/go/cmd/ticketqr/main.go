// Command ticketqr is the single entrypoint for every endpoint.
//
// On Lambda (AWS_LAMBDA_RUNTIME_API is set by the runtime) it serves API Gateway HTTP API events;
// elsewhere it starts a local HTTP server that feeds the same handler.
package main

import (
	"os"

	"github.com/aws/aws-lambda-go/lambda"
)

func main() {
	if os.Getenv("AWS_LAMBDA_RUNTIME_API") != "" {
		lambda.Start(mustNewHandlers().Route)
		return
	}
	runLocal()
}
