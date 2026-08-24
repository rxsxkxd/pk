// Package httpapi はチケット QR API の HTTP 層(クリーンアーキテクチャ: インバウンドアダプタ)。
// API Gateway HTTP API(payload v2)のイベントを package ticket の呼び出しに変換し、結果を戻す: ルーティング、
// アップロードの読み込み、署名付き URL、エラーレスポンス(errors.go が ticket のビジネスエラーを対応付ける)、HTML ビュー。
package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"

	"ticketqr/internal/imageinput"
	"ticketqr/internal/qr"
	"ticketqr/internal/signer"
	"ticketqr/internal/ticket"
	"ticketqr/internal/view"
)

type (
	Request  = events.APIGatewayV2HTTPRequest
	Response = events.APIGatewayV2HTTPResponse
)

type Handlers struct {
	PublicBaseURL string
	PublicOrigin  string
	Ports         ticket.Ports
	Signer        *signer.Signer
	View          *view.Renderer
	Logger        *slog.Logger
	// MaxImageBytes はこのデプロイのアップロード上限(MAX_IMAGE_BYTES)で、最大でも imageinput.MaxBytes。
	// 0 = imageinput.MaxBytes。
	MaxImageBytes int
}

// GrantInline はパターン A(QR インライン付与 API): POST /v1/tickets/qr-inline(multipart の画像を受け取り、base64 の QR を含む JSON を返す)。
func (h *Handlers) GrantInline(ctx context.Context, req Request) (Response, error) {
	return h.run(ctx, req, "grant-inline", h.jsonError, func() (Response, error) {
		img, err := readUpload(req, h.maxImageBytes())
		if err != nil {
			return Response{}, err
		}
		t, err := ticket.VerifyAndGrant(ctx, h.Ports, img)
		if err != nil {
			return Response{}, err
		}
		png, err := qr.PNG(t.Code)
		if err != nil {
			return Response{}, err
		}

		type qrOut struct {
			MimeType string `json:"mimeType"`
			Data     string `json:"data"`
		}
		out, err := json.Marshal(struct {
			TicketCode string `json:"ticketCode"`
			IssuedAt   string `json:"issuedAt"`
			QR         qrOut  `json:"qr"`
		}{t.Code, t.IssuedAt.Format(time.RFC3339), qrOut{"image/png", base64.StdEncoding.EncodeToString(png)}})
		if err != nil {
			return Response{}, err
		}
		return jsonResponse(http.StatusCreated, out), nil
	})
}

// Grant はパターン B-1(チケット付与 API): POST /v1/tickets(multipart の画像)。応答は Accept によって変わる:
//   - ブラウザのフォーム(application/json なし)はビュー(B-3)への 303 を受け取り、エラーは HTML;
//   - application/json を求めるクライアント(SPA)は署名付き QR URL を含む 201 の JSON を受け取り、エラーは JSON。
func (h *Handlers) Grant(ctx context.Context, req Request) (Response, error) {
	asJSON := acceptsJSON(req)
	onError := h.htmlError
	if asJSON {
		onError = h.jsonError
	}
	return h.run(ctx, req, "grant", onError, func() (Response, error) {
		img, err := readUpload(req, h.maxImageBytes())
		if err != nil {
			return Response{}, err
		}
		t, err := ticket.VerifyAndGrant(ctx, h.Ports, img)
		if err != nil {
			return Response{}, err
		}
		if !asJSON {
			return Response{
				StatusCode: http.StatusSeeOther,
				Headers:    withCommon(map[string]string{"Location": h.ticketURL(t.Code, "view"), "Vary": "Accept"}),
			}, nil
		}
		out, err := json.Marshal(struct {
			TicketCode string `json:"ticketCode"`
			IssuedAt   string `json:"issuedAt"`
			Sig        string `json:"sig"`
			QRURL      string `json:"qrUrl"`
		}{t.Code, t.IssuedAt.Format(time.RFC3339), h.Signer.Sign(t.Code), h.ticketURL(t.Code, "qr")})
		if err != nil {
			return Response{}, err
		}
		res := jsonResponse(http.StatusCreated, out)
		res.Headers["Vary"] = "Accept"
		return res, nil
	})
}

// GetView はパターン B-3: GET /v1/tickets/{ticketCode}/view?sig=...
func (h *Handlers) GetView(ctx context.Context, req Request) (Response, error) {
	return h.run(ctx, req, "get-view", h.htmlError, func() (Response, error) {
		code, err := h.verified(req)
		if err != nil {
			return Response{}, err
		}
		body, err := h.View.Ticket(code, h.ticketURL(code, "qr"))
		if err != nil {
			return Response{}, err
		}
		return h.htmlResponse(http.StatusOK, body), nil
	})
}

// GetQR はパターン B-2: GET /v1/tickets/{ticketCode}/qr?sig=...
func (h *Handlers) GetQR(ctx context.Context, req Request) (Response, error) {
	return h.run(ctx, req, "get-qr", h.jsonError, func() (Response, error) {
		code, err := h.verified(req)
		if err != nil {
			return Response{}, err
		}
		png, err := qr.PNG(code)
		if err != nil {
			return Response{}, err
		}
		return Response{
			StatusCode:      http.StatusOK,
			Headers:         withCommon(map[string]string{"Content-Type": "image/png"}),
			Body:            base64.StdEncoding.EncodeToString(png),
			IsBase64Encoded: true,
		}, nil
	})
}

// run はリクエストをログに記録し、あらゆるエラーをエンドポイントのエラー形式に変換する。
// Go のエラーは決して返さないので、API Gateway は常にこちらのレスポンスを受け取る。
func (h *Handlers) run(ctx context.Context, req Request, endpoint string,
	onError func(*apiError) Response, fn func() (Response, error)) (Response, error) {
	start := time.Now()
	log := h.Logger.With("requestId", req.RequestContext.RequestID, "endpoint", endpoint)

	res, err := fn()
	if err != nil {
		appErr := toAPIError(err)
		if appErr.Status >= 500 {
			log.ErrorContext(ctx, "request failed", "error", err)
		}
		res = onError(appErr)
	}
	fields := []any{"status", res.StatusCode, "durationMs", time.Since(start).Milliseconds()}
	if clientEndpoints[endpoint] {
		fields = append(fields, clientAttr(req))
	}
	log.InfoContext(ctx, "request completed", fields...)
	return res, nil
}

// clientEndpoints はブラウザから画像を受け取る。完了ログにはブラウザの自己申告も記録し、
// CloudWatch Logs でブラウザと OS のバージョンを集計できるようにする(DESIGN.md 10)。
var clientEndpoints = map[string]bool{"grant-inline": true, "grant": true}

// clientHeaders はログのキーを、そのまま記録するリクエストヘッダに対応付ける: User-Agent と User-Agent
// Client Hints(低エントロピーのものは Chromium がデフォルトで送る。プラットフォームのバージョンは要求時のみ)。
var clientHeaders = [][2]string{
	{"userAgent", "User-Agent"},
	{"secChUa", "Sec-CH-UA"},
	{"secChUaMobile", "Sec-CH-UA-Mobile"},
	{"secChUaPlatform", "Sec-CH-UA-Platform"},
	{"secChUaPlatformVersion", "Sec-CH-UA-Platform-Version"},
}

// maxClientHeaderLen はログに出す各ヘッダ値の長さの上限(クライアントが制御できる値のため)。
const maxClientHeaderLen = 512

// clientAttr は req に存在するヘッダからなる "client" ロググループを返す(空のグループは省かれる)。
func clientAttr(req Request) slog.Attr {
	var attrs []any
	for _, h := range clientHeaders {
		v := header(req, h[1])
		if v == "" {
			continue
		}
		if len(v) > maxClientHeaderLen {
			v = strings.ToValidUTF8(v[:maxClientHeaderLen], "")
		}
		attrs = append(attrs, slog.String(h[0], v))
	}
	return slog.Group("client", attrs...)
}

func (h *Handlers) verified(req Request) (string, error) {
	code := req.PathParameters["ticketCode"]
	if code == "" || !h.Signer.Verify(code, req.QueryStringParameters["sig"]) {
		return "", forbidden()
	}
	return code, nil
}

func (h *Handlers) ticketURL(code, resource string) string {
	return h.PublicBaseURL + "/v1/tickets/" + url.PathEscape(code) + "/" + resource +
		"?sig=" + url.QueryEscape(h.Signer.Sign(code))
}

func (h *Handlers) jsonError(e *apiError) Response {
	type errBody struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	body, _ := json.Marshal(struct {
		Error errBody `json:"error"`
	}{errBody{e.Code, e.Message}})
	return jsonResponse(e.Status, body)
}

func (h *Handlers) htmlError(e *apiError) Response {
	body, err := h.View.Error(e.Code, e.Message)
	if err != nil {
		return Response{StatusCode: e.Status, Headers: withCommon(map[string]string{"Content-Type": "text/plain; charset=utf-8"}), Body: e.Code}
	}
	return h.htmlResponse(e.Status, body)
}

func (h *Handlers) htmlResponse(status int, body []byte) Response {
	return Response{
		StatusCode: status,
		Headers: withCommon(map[string]string{
			"Content-Type":            "text/html; charset=utf-8",
			"Content-Security-Policy": "default-src 'none'; img-src " + h.PublicOrigin + "; style-src 'unsafe-inline'",
			"Referrer-Policy":         "no-referrer",
		}),
		Body: string(body),
	}
}

func jsonResponse(status int, body []byte) Response {
	return Response{
		StatusCode: status,
		Headers:    withCommon(map[string]string{"Content-Type": "application/json; charset=utf-8"}),
		Body:       string(body),
	}
}

func withCommon(h map[string]string) map[string]string {
	h["Cache-Control"] = "no-store"
	h["X-Content-Type-Options"] = "nosniff"
	h["X-Robots-Tag"] = "noindex, nofollow, noarchive" // 検索結果に載せない(infra/NOINDEX.md)
	return h
}

func requestBody(req Request) ([]byte, error) {
	if !req.IsBase64Encoded {
		return []byte(req.Body), nil
	}
	b, err := base64.StdEncoding.DecodeString(req.Body)
	if err != nil {
		return nil, badRequest("invalid request body encoding")
	}
	return b, nil
}

// acceptsJSON はクライアントが JSON の応答を求めたか(Accept に application/json を含むか)を返す。
func acceptsJSON(req Request) bool {
	return strings.Contains(strings.ToLower(header(req, "Accept")), "application/json")
}

// header はヘッダを大文字小文字を区別せずに探す(API Gateway v2 は名前を小文字化するが、ローカルアダプタはしないことがある)。
func header(req Request, name string) string {
	for k, v := range req.Headers {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

func (h *Handlers) maxImageBytes() int {
	if h.MaxImageBytes > 0 && h.MaxImageBytes < imageinput.MaxBytes {
		return h.MaxImageBytes
	}
	return imageinput.MaxBytes
}

// readUpload は multipart の "image" フィールドから証明書画像を読み込み、サイズ上限(maxBytes)を
// 適用して形式を判別する。
// その形式を受け付けるかどうかは ticket.VerifyAndGrant が決める。
func readUpload(req Request, maxBytes int) (ticket.CertificateImage, error) {
	data, err := readFormImage(req, maxBytes)
	if err != nil {
		return ticket.CertificateImage{}, err
	}
	if len(data) > maxBytes {
		return ticket.CertificateImage{}, payloadTooLarge(fmt.Sprintf("image must be %d bytes or less", maxBytes))
	}
	return ticket.CertificateImage{Data: data, MimeType: imageinput.Detect(data)}, nil
}

// readFormImage は multipart の "image" フィールド(最初のもの)の生バイトを返す。パート自身の
// Content-Type は無視し、形式は後でマジックバイトから判別する。Node 版と同様、ボディ全体が正しい
// multipart でなければならない: Lambda ではボディはすでにメモリ上にあるので、画像パートで
// 読み取りを止めても得るものはない。
func readFormImage(req Request, maxBytes int) ([]byte, error) {
	mt, params, err := mime.ParseMediaType(header(req, "Content-Type"))
	if err != nil || mt != "multipart/form-data" || params["boundary"] == "" {
		return nil, unsupportedMediaType("Content-Type must be multipart/form-data")
	}
	body, err := requestBody(req)
	if err != nil {
		return nil, err
	}
	mr := multipart.NewReader(bytes.NewReader(body), params["boundary"])
	var data []byte
	found := false
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, badRequest("invalid multipart body")
		}
		if found || part.FormName() != "image" {
			continue
		}
		if data, err = io.ReadAll(io.LimitReader(part, int64(maxBytes)+1)); err != nil {
			return nil, badRequest("invalid multipart body")
		}
		found = true
	}
	if !found {
		return nil, badRequest("image is required")
	}
	return data, nil
}
