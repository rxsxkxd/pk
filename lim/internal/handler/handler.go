// Package handler は S3 イベントを受けて画像をマスキングする本体。
package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

	"github.com/rxsxkxd/lim/internal/config"
	"github.com/rxsxkxd/lim/internal/masking"
	"github.com/rxsxkxd/lim/internal/metrics"
	"github.com/rxsxkxd/lim/internal/s3key"
)

// S3API は利用する S3 操作だけを切り出したもの。テストで差し替える。
type S3API interface {
	HeadObject(context.Context, *s3.HeadObjectInput, ...func(*s3.Options)) (*s3.HeadObjectOutput, error)
	GetObject(context.Context, *s3.GetObjectInput, ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	PutObject(context.Context, *s3.PutObjectInput, ...func(*s3.Options)) (*s3.PutObjectOutput, error)
}

// エラー型は masking パッケージのものをそのまま使う。
// 分類（恒久エラーか一時エラーか）が DLQ 送出とメトリクスの判断に直結する。
type (
	// ValidationError はリトライしても解消しない恒久的な入力エラー。
	ValidationError = masking.ValidationError
	// StrengthError はマスク強度の自己検証に失敗した場合のエラー。出力は行われない。
	StrengthError = masking.StrengthError
)

func invalid(format string, a ...any) error {
	return &ValidationError{Reason: fmt.Sprintf(format, a...)}
}

// Handler は S3 イベントハンドラ。
type Handler struct {
	S3  S3API
	Cfg config.Config
	Log *slog.Logger
}

// Request はリクエスト起動のペイロード。キーの変数部分だけを受け取り、
// 固定部分（バケット・プレフィックス・infix）は Lambda 側の設定から組み立てる。
type Request struct {
	s3key.Parts
}

// Response はリクエスト起動の応答。
type Response struct {
	SourceKey string  `json:"sourceKey"`
	OutputKey string  `json:"outputKey"`
	Skipped   bool    `json:"skipped"`
	RadiusPx  float64 `json:"radiusPx,omitempty"`
	Score     float64 `json:"strengthScore,omitempty"`
}

// Handle は S3 通知とリクエストの両方を受ける。
//
// どちらで起動されたかはペイロードの形で判別する。Records を持つものは S3 通知、
// 変数を持つものはリクエストとして扱う。
func (h *Handler) Handle(ctx context.Context, payload json.RawMessage) (*Response, error) {
	var probe struct {
		Records []json.RawMessage `json:"Records"`
		X       string            `json:"x"`
	}
	if err := json.Unmarshal(payload, &probe); err != nil {
		return nil, invalid("cannot parse the event payload: %v", err)
	}

	switch {
	case len(probe.Records) > 0:
		return nil, h.handleS3Event(ctx, payload)
	case probe.X != "":
		return h.handleRequest(ctx, payload)
	default:
		return nil, invalid("payload is neither an S3 notification nor a request with key variables")
	}
}

// handleS3Event は S3 通知を処理する。通常 1 レコードだが複数前提で実装する。
func (h *Handler) handleS3Event(ctx context.Context, payload json.RawMessage) error {
	var ev events.S3Event
	if err := json.Unmarshal(payload, &ev); err != nil {
		return invalid("cannot parse the S3 notification: %v", err)
	}

	var errs []error
	for _, rec := range ev.Records {
		if err := h.handleRecord(ctx, rec); err != nil {
			emitFailureMetric(err)
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// handleRequest はリクエスト起動を処理する。
//
// S3 通知と違ってオブジェクトの ETag もサイズも分からないため、HeadObject で確かめる。
func (h *Handler) handleRequest(ctx context.Context, payload json.RawMessage) (*Response, error) {
	var req Request
	if err := json.Unmarshal(payload, &req); err != nil {
		return nil, invalid("cannot parse the request: %v", err)
	}

	srcKey, err := h.Cfg.Layout().Original(req.Parts)
	if err != nil {
		return nil, invalid("%v", err)
	}

	head, err := h.S3.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(h.Cfg.InputBucket),
		Key:    aws.String(srcKey),
	})
	if err != nil {
		if isNotFound(err) {
			return nil, invalid("object not found: s3://%s/%s", h.Cfg.InputBucket, srcKey)
		}
		return nil, fmt.Errorf("head source object: %w", err)
	}

	size := aws.ToInt64(head.ContentLength)
	etag := strings.Trim(aws.ToString(head.ETag), `"`)

	res, skipped, err := h.process(ctx, h.Cfg.InputBucket, srcKey, etag, size)
	if err != nil {
		emitFailureMetric(err)
		return nil, err
	}
	if skipped {
		dst, _ := h.Cfg.Layout().Masked(req.Parts)
		return &Response{SourceKey: srcKey, OutputKey: dst, Skipped: true}, nil
	}
	return &Response{
		SourceKey: srcKey,
		OutputKey: res.OutputKey,
		RadiusPx:  res.RadiusPx,
		Score:     res.Score,
	}, nil
}

type result struct {
	SourceKey   string
	OutputKey   string
	RadiusPx    float64
	Region      string
	Score       float64
	InputBytes  int
	OutputBytes int

	body        []byte
	contentType string
}

func (h *Handler) handleRecord(ctx context.Context, rec events.S3EventRecord) error {
	started := time.Now()

	srcBucket := rec.S3.Bucket.Name
	// S3 通知のキーはフォームエンコードされている。"+" はスペースを表すため
	// PathUnescape ではなく QueryUnescape を使う。
	srcKey, err := url.QueryUnescape(rec.S3.Object.URLDecodedKey)
	if err != nil || rec.S3.Object.URLDecodedKey == "" {
		srcKey, err = url.QueryUnescape(rec.S3.Object.Key)
		if err != nil {
			return invalid("cannot decode object key %q: %v", rec.S3.Object.Key, err)
		}
	}

	log := h.Log.With(
		slog.String("sourceBucket", srcBucket),
		slog.String("sourceKey", srcKey),
	)

	// 再帰ループ防止。マスク済みの出力が同じバケットの別 infix に落ちるため、
	// それを再度処理しにいかないようにする。
	_, infix, err := h.Cfg.Layout().Parse(srcKey)
	if err != nil {
		log.Warn("skip: key does not match the configured layout", slog.Any("reason", err))
		return nil
	}
	if infix != h.Cfg.OriginalInfix {
		log.Info("skip: not an original", slog.String("infix", infix))
		return nil
	}

	res, skipped, err := h.process(ctx, srcBucket, srcKey, strings.Trim(rec.S3.Object.ETag, `"`), rec.S3.Object.Size)
	if err != nil {
		return err
	}
	if skipped {
		log.Info("skip: already processed")
		return nil
	}

	metrics.Emit(
		metrics.Count("ImagesMasked", 1),
		metrics.Count("StrengthCheckFailures", 0),
		metrics.Metric{Name: "ProcessingDurationMs", Unit: "Milliseconds", Value: float64(time.Since(started).Milliseconds())},
		metrics.Metric{Name: "StrengthScore", Unit: "None", Value: res.Score},
		metrics.Metric{Name: "InputBytes", Unit: "Bytes", Value: float64(res.InputBytes)},
		metrics.Metric{Name: "OutputBytes", Unit: "Bytes", Value: float64(res.OutputBytes)},
	)

	log.Info("masked",
		slog.String("outputKey", res.OutputKey),
		slog.Float64("radiusPx", res.RadiusPx),
		slog.String("maskRegion", res.Region),
		slog.Float64("strengthScore", res.Score),
		slog.Int("inputBytes", res.InputBytes),
		slog.Int("outputBytes", res.OutputBytes),
		slog.Int64("durationMs", time.Since(started).Milliseconds()),
	)
	return nil
}

// process は 1 オブジェクトを取得してマスクし、出力する。
// 起動方式によらず共通の処理。既に処理済みなら skipped を返す。
func (h *Handler) process(ctx context.Context, bucket, srcKey, srcETag string, size int64) (*result, bool, error) {
	if bucket != h.Cfg.InputBucket {
		return nil, false, invalid("bucket %q is not the configured input bucket %q", bucket, h.Cfg.InputBucket)
	}
	if size > h.Cfg.MaxInputBytes {
		return nil, false, invalid("object size %d exceeds limit %d", size, h.Cfg.MaxInputBytes)
	}

	parts, _, err := h.Cfg.Layout().Parse(srcKey)
	if err != nil {
		return nil, false, invalid("%v", err)
	}
	dstKey, err := h.Cfg.Layout().Masked(parts)
	if err != nil {
		return nil, false, invalid("%v", err)
	}

	// 冪等性チェック。S3 通知は at-least-once なので重複配信があり得る。
	if done, err := h.alreadyProcessed(ctx, dstKey, srcETag); err != nil {
		return nil, false, err
	} else if done {
		return nil, true, nil
	}

	raw, err := h.fetch(ctx, bucket, srcKey, srcETag)
	if err != nil {
		return nil, false, err
	}

	res, err := h.mask(raw, srcKey, dstKey)
	if err != nil {
		return nil, false, err
	}

	if err := h.put(ctx, res, bucket, srcKey, srcETag); err != nil {
		return nil, false, err
	}
	return res, false, nil
}

// emitFailureMetric は失敗の種類別にメトリクスを出す。
// StrengthCheckFailures は 0 であるべき値で、1 でも立てばアラームになる。
func emitFailureMetric(err error) {
	var se *StrengthError
	if errors.As(err, &se) {
		metrics.Emit(metrics.Count("StrengthCheckFailures", 1))
		return
	}
	var ve *ValidationError
	if errors.As(err, &ve) {
		metrics.Emit(metrics.Count("ValidationErrors", 1))
		return
	}
	metrics.Emit(metrics.Count("TransientErrors", 1))
}

func (h *Handler) alreadyProcessed(ctx context.Context, dstKey, srcETag string) (bool, error) {
	out, err := h.S3.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(h.Cfg.OutputBucket),
		Key:    aws.String(dstKey),
	})
	if err != nil {
		if isNotFound(err) {
			return false, nil
		}
		// 404 相当以外は一時エラーの可能性があるためリトライさせる。
		return false, fmt.Errorf("head output object: %w", err)
	}
	return out.Metadata["source-etag"] == srcETag &&
		out.Metadata["masking-policy-version"] == h.Cfg.PolicyVersion, nil
}

// isNotFound は「オブジェクトが無い」ことを示すエラーかを判定する。
func isNotFound(err error) bool {
	var nf *types.NotFound
	if errors.As(err, &nf) {
		return true
	}
	var noKey *types.NoSuchKey
	if errors.As(err, &noKey) {
		return true
	}
	var apiErr interface{ ErrorCode() string }
	return errors.As(err, &apiErr) && apiErr.ErrorCode() == "NotFound"
}

func (h *Handler) fetch(ctx context.Context, bucket, key, etag string) ([]byte, error) {
	in := &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)}
	if etag != "" {
		// 処理中に元オブジェクトが差し替わった場合に、別物をマスクしてしまうのを防ぐ。
		in.IfMatch = aws.String(`"` + etag + `"`)
	}
	out, err := h.S3.GetObject(ctx, in)
	if err != nil {
		return nil, fmt.Errorf("get source object: %w", err)
	}
	defer out.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(out.Body, h.Cfg.MaxInputBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read source object: %w", err)
	}
	if int64(len(raw)) > h.Cfg.MaxInputBytes {
		return nil, invalid("object body exceeds limit %d", h.Cfg.MaxInputBytes)
	}
	return raw, nil
}

// mask は設定を masking.Options に写して処理を委譲する。
// 強度検証に落ちた場合はエラーを返し、呼び出し側は PutObject を行わない
// （fail-closed、設計書 §10.4）。
func (h *Handler) mask(raw []byte, srcKey, dstKey string) (*result, error) {
	out, err := masking.Apply(raw, masking.Options{
		MaskHeightRatio: h.Cfg.MaskHeightRatio,
		BlurRatio:       h.Cfg.BlurRatio,
		MinBlurRadiusPx: h.Cfg.MinBlurRadiusPx,
		BlurPasses:      h.Cfg.BlurPasses,
		DownscaleFactor: h.Cfg.DownscaleFactor,
		StrengthBlockPx: h.Cfg.StrengthBlockPx,
		MaxLaplacianVar: h.Cfg.MaxLaplacianVar,
		MaxPixels:       h.Cfg.MaxInputPixels,
		JPEGQuality:     h.Cfg.JPEGQuality,
	})
	if err != nil {
		return nil, err
	}
	return &result{
		SourceKey:   srcKey,
		OutputKey:   dstKey,
		RadiusPx:    out.RadiusPx,
		Region:      out.Region,
		Score:       out.Score,
		InputBytes:  len(raw),
		OutputBytes: len(out.Body),
		body:        out.Body,
		contentType: out.ContentType,
	}, nil
}

func (h *Handler) put(ctx context.Context, res *result, srcBucket, srcKey, srcETag string) error {
	_, err := h.S3.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(h.Cfg.OutputBucket),
		Key:         aws.String(res.OutputKey),
		Body:        bytes.NewReader(res.body),
		ContentType: aws.String(res.contentType),
		Metadata: map[string]string{
			"source-bucket":          srcBucket,
			"source-key":             srcKey,
			"source-etag":            srcETag,
			"masking-policy-version": h.Cfg.PolicyVersion,
			"blur-radius-px":         strconv.FormatFloat(res.RadiusPx, 'f', 1, 64),
			"downscale-factor":       strconv.Itoa(h.Cfg.DownscaleFactor),
			"mask-region":            res.Region,
			"strength-score":         strconv.FormatFloat(res.Score, 'f', 3, 64),
		},
	})
	if err != nil {
		return fmt.Errorf("put masked object: %w", err)
	}
	return nil
}
