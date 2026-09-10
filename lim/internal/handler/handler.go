// Package handler は S3 イベントを受けて画像をマスキングする本体。
package handler

import (
	"bytes"
	"context"
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

// Handle は S3 通知を処理する。通常 1 レコードだが複数前提で実装する。
func (h *Handler) Handle(ctx context.Context, ev events.S3Event) error {
	var errs []error
	for _, rec := range ev.Records {
		if err := h.handleRecord(ctx, rec); err != nil {
			emitFailureMetric(err)
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
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

	// 再帰ループ防止。出力が同一バケットの出力プレフィックス配下に落ちた場合に
	// 自分自身を再度トリガするのを止める（バケット分離に加えた多重防御）。
	if srcBucket == h.Cfg.OutputBucket && strings.HasPrefix(srcKey, h.Cfg.OutputPrefix) {
		log.Info("skip: object is under output prefix")
		return nil
	}
	if !strings.HasPrefix(srcKey, h.Cfg.InputPrefix) {
		log.Warn("skip: object is outside input prefix")
		return nil
	}

	if size := rec.S3.Object.Size; size > h.Cfg.MaxInputBytes {
		return invalid("object size %d exceeds limit %d", size, h.Cfg.MaxInputBytes)
	}

	srcETag := strings.Trim(rec.S3.Object.ETag, `"`)
	dstKey := h.outputKey(srcKey)

	// 冪等性チェック。S3 通知は at-least-once なので重複配信があり得る。
	if done, err := h.alreadyProcessed(ctx, dstKey, srcETag); err != nil {
		return err
	} else if done {
		log.Info("skip: already processed", slog.String("outputKey", dstKey))
		return nil
	}

	raw, err := h.fetch(ctx, srcBucket, srcKey, srcETag)
	if err != nil {
		return err
	}

	res, err := h.mask(raw, srcKey, dstKey)
	if err != nil {
		return err
	}

	if err := h.put(ctx, res, srcBucket, srcKey, srcETag); err != nil {
		return err
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

// outputKey は設計書 §8.2 のキー規約。
// 入力キーとポリシー版から決定的に決まるため、冪等性の基礎になる。
func (h *Handler) outputKey(srcKey string) string {
	rel := strings.TrimPrefix(srcKey, h.Cfg.InputPrefix)
	return h.Cfg.OutputPrefix + h.Cfg.PolicyVersion + "/" + rel
}

func (h *Handler) alreadyProcessed(ctx context.Context, dstKey, srcETag string) (bool, error) {
	out, err := h.S3.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(h.Cfg.OutputBucket),
		Key:    aws.String(dstKey),
	})
	if err != nil {
		var nf *types.NotFound
		if errors.As(err, &nf) {
			return false, nil
		}
		var noKey *types.NoSuchKey
		if errors.As(err, &noKey) {
			return false, nil
		}
		// 404 相当以外は一時エラーの可能性があるためリトライさせる。
		var apiErr interface{ ErrorCode() string }
		if errors.As(err, &apiErr) && apiErr.ErrorCode() == "NotFound" {
			return false, nil
		}
		return false, fmt.Errorf("head output object: %w", err)
	}
	return out.Metadata["source-etag"] == srcETag &&
		out.Metadata["masking-policy-version"] == h.Cfg.PolicyVersion, nil
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
		DownscaleFactor: h.Cfg.DownscaleFactor,
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
