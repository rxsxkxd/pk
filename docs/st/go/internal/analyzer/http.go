package analyzer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"ticketqr/internal/ticket"
)

// HTTPConfig は ANALYZER_MODE=http 用のクライアント設定。
type HTTPConfig struct {
	URL     string
	APIKey  string        // 任意: 設定されているときだけ x-api-key として送る
	Timeout time.Duration // 1 回の試行あたり
	Logger  *slog.Logger  // すべてのレスポンスボディをそのままログに出す(nil なら slog.Default())
}

// HTTP は画像をそのまま(application/octet-stream、設定されていれば x-api-key 付きで)解析サーバに POST する。
// 5xx、タイムアウト、通信エラーのときは 1 回だけリトライし、4xx と不正なレスポンスはリトライしない。
// レスポンスボディはすべてそのままログに出し("analyzer response": ステータスと生のボディ)、その後 "result" だけを読む。
type HTTP struct {
	cfg    HTTPConfig
	client *http.Client
}

const maxResponseBytes = 1 << 20

func NewHTTP(cfg HTTPConfig) *HTTP {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &HTTP{cfg: cfg, client: &http.Client{}}
}

func (h *HTTP) Verify(ctx context.Context, img ticket.CertificateImage) (ticket.Verdict, error) {
	res, retry, err := h.attempt(ctx, img)
	if err != nil && retry {
		res, _, err = h.attempt(ctx, img)
	}
	return res, err
}

// attempt はリクエストを 1 回送る。bool は失敗がリトライに値するかを返す。
func (h *HTTP) attempt(ctx context.Context, img ticket.CertificateImage) (ticket.Verdict, bool, error) {
	ctx, cancel := context.WithTimeout(ctx, h.cfg.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.cfg.URL, bytes.NewReader(img.Data))
	if err != nil {
		return ticket.Verdict{}, false, fmt.Errorf("%w: build request: %v", ticket.ErrVerifierUpstream, err)
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	if h.cfg.APIKey != "" {
		req.Header.Set("X-Api-Key", h.cfg.APIKey)
	}

	resp, err := h.client.Do(req)
	if err != nil {
		return ticket.Verdict{}, true, transportError(ctx, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return ticket.Verdict{}, true, transportError(ctx, err)
	}
	// レスポンスボディは届いたまま(パースせず)ログに出す。2xx でもそれ以外のどのステータスでも同様。
	level := slog.LevelInfo
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		level = slog.LevelWarn
	}
	h.cfg.Logger.Log(ctx, level, "analyzer response", "status", resp.StatusCode, "body", string(body))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return ticket.Verdict{}, resp.StatusCode >= 500, fmt.Errorf("%w: analyzer returned %d", ticket.ErrVerifierUpstream, resp.StatusCode)
	}
	res, err := parseResponse(body)
	if err != nil {
		return ticket.Verdict{}, false, fmt.Errorf("%w: bad analyzer response: %v", ticket.ErrVerifierUpstream, err)
	}
	return res, false, nil
}

// transportError は送信またはボディ読み込みの失敗を、期限切れなら ticket.ErrVerifierTimeout、それ以外なら ticket.ErrVerifierUpstream でラップする。
func transportError(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("%w: %v", ticket.ErrVerifierTimeout, err)
	}
	return fmt.Errorf("%w: %v", ticket.ErrVerifierUpstream, err)
}

// parseResponse は解析サーバのレスポンス {"confidence", "detected", "reason", "result", "status"}
// (analyzer-stub/DESIGN.md 3.2)を読む。API が見るのは "result" だけ: PASS、REJECT、RETRY のいずれかで、
// それ以外は不正なレスポンスとする。
func parseResponse(body []byte) (ticket.Verdict, error) {
	var out struct {
		Result ticket.Result `json:"result"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return ticket.Verdict{}, err
	}
	switch out.Result {
	case ticket.ResultPass, ticket.ResultReject, ticket.ResultRetry:
		return ticket.Verdict{Result: out.Result}, nil
	default:
		return ticket.Verdict{}, fmt.Errorf(`"result" must be PASS, REJECT or RETRY, got %q`, out.Result)
	}
}
