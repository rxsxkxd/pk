package main

import (
	"github.com/aws/aws-lambda-go/lambda"

	"ticketqr/go/internal/app"
)

func main() {
	lambda.Start(app.MustNew().GetView)
}
