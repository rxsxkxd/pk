// Package handler は S3 イベントを受けて画像をマスキングする本体。
package handler

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
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
	"github.com/rxsxkxd/lim/internal/imaging"
	"github.com/rxsxkxd/lim/internal/metrics"
)

// S3API は利用する S3 操作だけを切り出したもの。テストで差し替える。
type S3API interface {
	HeadObject(context.Context, *s3.HeadObjectInput, ...func(*s3.Options)) (*s3.HeadObjectOutput, error)
	GetObject(context.Context, *s3.GetObjectInput, ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	PutObject(context.Context, *s3.PutObjectInput, ...func(*s3.Options)) (*s3.PutObjectOutput, error)
}

// ValidationError はリトライしても解消しない恒久的な入力エラー。
// 取りこぼしを避けるため成功扱いにはせず、そのまま DLQ へ送る（設計書 §10.1）。
type ValidationError struct{ Reason string }

func (e *ValidationError) Error() string { return "validation: " + e.Reason }

func invalid(format string, a ...any) error {
	return &ValidationError{Reason: fmt.Sprintf(format, a...)}
}

// StrengthError はマスク強度の自己検証に失敗した場合のエラー（設計書 §12.4）。
// この場合、出力は一切書かれない。
type StrengthError struct {
	Score float64
	Limit float64
}

func (e *StrengthError) Error() string {
	return fmt.Sprintf("mask strength check failed: laplacian variance %.3f > %.3f", e.Score, e.Limit)
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

// mask はデコードからエンコードまでを行う。強度検証に落ちた場合はエラーを返し、
// 呼び出し側は PutObject を行わない（fail-closed、設計書 §10.4）。
func (h *Handler) mask(raw []byte, srcKey, dstKey string) (*result, error) {
	// 全体をデコードする前に寸法だけ確認し、decompression bomb を弾く。
	cfg, format, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return nil, invalid("cannot decode image header: %v", err)
	}
	if format != "jpeg" && format != "png" {
		return nil, invalid("unsupported format %q (jpeg/png only)", format)
	}
	if int64(cfg.Width)*int64(cfg.Height) > h.Cfg.MaxInputPixels {
		return nil, invalid("image %dx%d exceeds pixel limit %d", cfg.Width, cfg.Height, h.Cfg.MaxInputPixels)
	}

	decoded, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, invalid("cannot decode image: %v", err)
	}

	img := imaging.ToRGBA(decoded)
	if format == "jpeg" {
		img = imaging.ApplyOrientation(img, imaging.JPEGOrientation(raw))
	}

	w, h0 := img.Rect.Dx(), img.Rect.Dy()
	// 半径は画像全体の短辺から決める。隠したい特徴（文字の線幅など）の大きさは
	// 領域の高さではなく画像の解像度に比例するため。
	radius := imaging.BlurRadius(w, h0, h.Cfg.BlurRatio, h.Cfg.MinBlurRadiusPx)

	// 検出処理は使わず、画像上部の固定矩形だけをマスクする。
	region := imaging.TopRegion(w, h0, h.Cfg.MaskHeightRatio)
	part := imaging.Crop(img, region)

	// 領域だけを切り出してぼかすことで、マスク対象の情報が
	// 境界をまたいで非マスク領域へにじみ出すのを防ぐ。
	// 既定では factor=1 で素通り。強度を上げる必要が出たら環境変数だけで切り替える。
	if f := h.Cfg.DownscaleFactor; f > 1 {
		small := imaging.Downscale(part, f)
		small = imaging.GaussianBlur(small, radius/float64(f))
		part = imaging.Upscale(small, region.Dx(), region.Dy())
	} else {
		part = imaging.GaussianBlur(part, radius)
	}
	imaging.Paste(img, part, region.Min)

	// 強度検証は「マスクした領域だけ」を対象にする。
	// 画像全体で測ると、非マスク領域の鮮明さに引きずられて必ず不合格になる。
	score := imaging.LaplacianVariance(part)
	if score > h.Cfg.MaxLaplacianVar {
		return nil, &StrengthError{Score: score, Limit: h.Cfg.MaxLaplacianVar}
	}

	// Go の標準エンコーダは EXIF / XMP / 埋め込みサムネイルを一切書き出さない。
	// これにより FR-9（メタデータ完全除去）が構造的に満たされる。
	var buf bytes.Buffer
	switch format {
	case "jpeg":
		err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: h.Cfg.JPEGQuality})
	case "png":
		enc := png.Encoder{CompressionLevel: png.DefaultCompression}
		err = enc.Encode(&buf, img)
	}
	if err != nil {
		return nil, fmt.Errorf("encode output: %w", err)
	}

	return &result{
		SourceKey:   srcKey,
		OutputKey:   dstKey,
		RadiusPx:    radius,
		Region:      fmt.Sprintf("top %.0f%% (0,0,%d,%d)", h.Cfg.MaskHeightRatio*100, region.Dx(), region.Dy()),
		Score:       score,
		InputBytes:  len(raw),
		OutputBytes: buf.Len(),
		body:        buf.Bytes(),
		contentType: "image/" + format,
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
