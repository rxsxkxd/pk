// Package analyzer は外部の画像解析サーバのクライアント: ticket.Verifier を実装する
// (クリーンアーキテクチャ: アウトバウンドアダプタ)。
//
// リクエスト形式は固定: Content-Type application/octet-stream で、生の画像バイト列
// (ticket.CertificateImage.Data)をボディとして POST する。ANALYZER_MODE=mock はプロセス内で PASS を返し、ANALYZER_MODE=http
// はサーバに POST する(http.go、analyzer-stub/DESIGN.md 3)。API はレスポンスの "result" だけを読む。
package analyzer

import (
	"context"
	"fmt"

	"ticketqr/internal/ticket"
)

// New は ANALYZER_MODE で選ばれた解析器を返す。httpCfg は "http" のときだけ使う。
func New(mode string, httpCfg HTTPConfig) (ticket.Verifier, error) {
	switch mode {
	case "mock":
		return AlwaysPass{}, nil
	case "http":
		return NewHTTP(httpCfg), nil
	default:
		return nil, fmt.Errorf("unsupported ANALYZER_MODE %q", mode)
	}
}

// AlwaysPass はプロセス内のモック(ANALYZER_MODE=mock): すべての画像が合格する。
type AlwaysPass struct{}

func (AlwaysPass) Verify(context.Context, ticket.CertificateImage) (ticket.Verdict, error) {
	return ticket.Verdict{Result: ticket.ResultPass}, nil
}
