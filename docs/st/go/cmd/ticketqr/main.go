// Command ticketqr はすべてのエンドポイントに共通の単一エントリポイント。
//
// Lambda 上(ランタイムが AWS_LAMBDA_RUNTIME_API を設定する)では API Gateway HTTP API のイベントを処理し、
// それ以外では同じハンドラに渡すローカル HTTP サーバを起動する。
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
