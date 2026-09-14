package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

	"github.com/rxsxkxd/lim/internal/config"
	"github.com/rxsxkxd/lim/internal/imaging"
	"github.com/rxsxkxd/lim/internal/s3key"
)

// fakeS3 は最小限のインメモリ S3。
type fakeS3 struct {
	objects map[string][]byte            // "bucket/key" -> body
	meta    map[string]map[string]string // "bucket/key" -> metadata
	puts    int
	gets    int
	getErr  error
}

func newFakeS3() *fakeS3 {
	return &fakeS3{objects: map[string][]byte{}, meta: map[string]map[string]string{}}
}

func (f *fakeS3) put(bucket, key string, body []byte, meta map[string]string) {
	f.objects[bucket+"/"+key] = body
	f.meta[bucket+"/"+key] = meta
}

func (f *fakeS3) HeadObject(_ context.Context, in *s3.HeadObjectInput, _ ...func(*s3.Options)) (*s3.HeadObjectOutput, error) {
	id := *in.Bucket + "/" + *in.Key
	if _, ok := f.objects[id]; !ok {
		return nil, &types.NotFound{}
	}
	return &s3.HeadObjectOutput{Metadata: f.meta[id]}, nil
}

func (f *fakeS3) GetObject(_ context.Context, in *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
	f.gets++
	if f.getErr != nil {
		return nil, f.getErr
	}
	body, ok := f.objects[*in.Bucket+"/"+*in.Key]
	if !ok {
		return nil, &types.NoSuchKey{}
	}
	return &s3.GetObjectOutput{Body: io.NopCloser(bytes.NewReader(body))}, nil
}

func (f *fakeS3) PutObject(_ context.Context, in *s3.PutObjectInput, _ ...func(*s3.Options)) (*s3.PutObjectOutput, error) {
	f.puts++
	body, err := io.ReadAll(in.Body)
	if err != nil {
		return nil, err
	}
	f.put(*in.Bucket, *in.Key, body, in.Metadata)
	return &s3.PutObjectOutput{ETag: aws.String(`"stub"`)}, nil
}

func testConfig() config.Config {
	return config.Config{
		InputBucket:     "shared",
		OutputBucket:    "shared",
		KeyPrefix:       "masking",
		OriginalInfix:   "original",
		PolicyVersion:   "v1",
		MaskHeightRatio: 0.5,
		BlurPasses:      2,
		StrengthBlockPx: 64,
		BlurRatio:       0.04,
		MinBlurRadiusPx: 8,
		DownscaleFactor: 1,
		MaxLaplacianVar: 15.0,
		MaxInputBytes:   20 * 1024 * 1024,
		MaxInputPixels:  64_000_000,
		JPEGQuality:     85,
	}
}

func newHandler(f *fakeS3, mutate ...func(*config.Config)) *Handler {
	cfg := testConfig()
	for _, m := range mutate {
		m(&cfg)
	}
	return &Handler{
		S3:  f,
		Cfg: cfg,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

// detailedJPEG は細い縞模様（文字の代わり）を描いた JPEG を返す。
func detailedJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.RGBA{255, 255, 255, 255}
			if (x/3)%2 == 0 {
				c = color.RGBA{0, 0, 0, 255}
			}
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func detailedPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.RGBA{0, 0, 0, 255}
			if (y/2)%2 == 0 {
				c = color.RGBA{255, 0, 0, 255}
			}
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// origKey は原本のキーを組み立てる。testConfig のレイアウトに合わせている。
func origKey(x, y, z, n string) string {
	return "masking/" + x + "/" + y + "/original/" + z + "/" + n
}

// maskedKey はマスク済みのキー。infix だけが異なる。
func maskedKey(x, y, z, n string) string {
	return "masking/" + x + "/" + y + "/v1/" + z + "/" + n
}

func s3Event(bucket, key string, size int64, etag string) json.RawMessage {
	return payload(events.S3Event{Records: []events.S3EventRecord{{
		S3: events.S3Entity{
			Bucket: events.S3Bucket{Name: bucket},
			Object: events.S3Object{Key: key, URLDecodedKey: key, Size: size, ETag: etag},
		},
	}}})
}

// payload は任意の値を Lambda のペイロード（JSON）にする。
func payload(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// request はリクエスト起動のペイロード。
func request(x, y, z, n string) json.RawMessage {
	return payload(map[string]string{"x": x, "y": y, "z": z, "n": n})
}

func TestHandleMasksImageAndWritesMetadata(t *testing.T) {
	f := newFakeS3()
	body := detailedJPEG(t, 400, 300)
	f.put("shared", origKey("tenant-a", "2026-09", "front", "doc.jpg"), body, nil)

	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("tenant-a", "2026-09", "front", "doc.jpg"), int64(len(body)), `"abc123"`)); err != nil {
		t.Fatalf("Handle: %v", err)
	}

	out, ok := f.objects["shared/"+maskedKey("tenant-a", "2026-09", "front", "doc.jpg")]
	if !ok {
		t.Fatalf("output object not written; objects = %v", keys(f.objects))
	}
	if len(out) == 0 {
		t.Fatal("output body is empty")
	}

	meta := f.meta["shared/"+maskedKey("tenant-a", "2026-09", "front", "doc.jpg")]
	for _, k := range []string{"source-bucket", "source-key", "source-etag", "masking-policy-version", "blur-radius-px", "strength-score"} {
		if meta[k] == "" {
			t.Errorf("metadata %q is missing", k)
		}
	}
	if meta["source-etag"] != "abc123" {
		t.Errorf("source-etag = %q, want abc123 (quotes stripped)", meta["source-etag"])
	}
	if meta["blur-radius-px"] != "12.0" {
		t.Errorf("blur-radius-px = %q, want 12.0", meta["blur-radius-px"])
	}
}

func TestHandleStripsAllMetadata(t *testing.T) {
	// FR-9: EXIF が付いた入力でも、出力には Exif マーカーが残らないこと。
	// JPEG の EXIF には未加工のサムネイルが埋まっていることがあり、
	// 残ると本体をぼかす意味がなくなる。
	f := newFakeS3()
	body := withFakeEXIF(detailedJPEG(t, 200, 200))
	if !bytes.Contains(body, []byte("Exif\x00\x00")) {
		t.Fatal("fixture does not contain an EXIF segment")
	}
	f.put("shared", origKey("x", "y", "z", "a.jpg"), body, nil)

	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.jpg"), int64(len(body)), "e1")); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	out := f.objects["shared/"+maskedKey("x", "y", "z", "a.jpg")]
	if bytes.Contains(out, []byte("Exif")) {
		t.Error("output still contains an EXIF segment")
	}
}

func TestHandlePNG(t *testing.T) {
	f := newFakeS3()
	body := detailedPNG(t, 300, 300)
	f.put("shared", origKey("x", "y", "z", "a.png"), body, nil)

	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(len(body)), "e1")); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	out, ok := f.objects["shared/"+maskedKey("x", "y", "z", "a.png")]
	if !ok {
		t.Fatal("output not written")
	}
	if _, format, err := image.Decode(bytes.NewReader(out)); err != nil || format != "png" {
		t.Errorf("output format = %q, err = %v; want png", format, err)
	}
}

func TestHandleFailsClosedOnWeakMask(t *testing.T) {
	// 強度検証に落ちたら PutObject を一切行わないこと（設計書 §10.4）。
	f := newFakeS3()
	body := detailedJPEG(t, 400, 300)
	f.put("shared", origKey("x", "y", "z", "a.jpg"), body, nil)

	h := newHandler(f, func(c *config.Config) {
		c.BlurRatio = 0.0001 // 実質ぼかさない
		c.MinBlurRadiusPx = 0.1
		c.MaxLaplacianVar = 0.01
	})
	_, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.jpg"), int64(len(body)), "e1"))
	if err == nil {
		t.Fatal("expected an error so the event goes to the DLQ")
	}
	var se *StrengthError
	if !errors.As(err, &se) {
		t.Errorf("error = %v, want StrengthError", err)
	}
	if f.puts != 0 {
		t.Errorf("PutObject was called %d times; must be 0 when the check fails", f.puts)
	}
}

func TestHandleSkipsObjectsUnderOutputPrefix(t *testing.T) {
	// 再帰ループ防止。出力を再度処理しにいかないこと。
	f := newFakeS3()
	h := newHandler(f)
	_, err := h.Handle(context.Background(), s3Event("shared", maskedKey("x", "y", "z", "a.jpg"), 100, "e1"))
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if f.gets != 0 || f.puts != 0 {
		t.Errorf("object was processed: gets=%d puts=%d", f.gets, f.puts)
	}
}

func TestHandleSkipsObjectsOutsideInputPrefix(t *testing.T) {
	f := newFakeS3()
	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", "other/x/y/original/z/a.jpg", 100, "e1")); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if f.gets != 0 {
		t.Errorf("gets = %d, want 0", f.gets)
	}
}

func TestHandleIsIdempotent(t *testing.T) {
	// S3 通知は at-least-once。同じイベントを 2 回投げても 1 回しか書かない。
	f := newFakeS3()
	body := detailedJPEG(t, 200, 200)
	f.put("shared", origKey("x", "y", "z", "a.jpg"), body, nil)

	h := newHandler(f)
	ev := s3Event("shared", origKey("x", "y", "z", "a.jpg"), int64(len(body)), "e1")
	for i := 0; i < 2; i++ {
		if _, err := h.Handle(context.Background(), ev); err != nil {
			t.Fatalf("Handle #%d: %v", i+1, err)
		}
	}
	if f.puts != 1 {
		t.Errorf("PutObject called %d times, want 1", f.puts)
	}
}

func TestHandleReprocessesWhenSourceChanged(t *testing.T) {
	// ETag が変わっていれば、同じキーでも作り直す。
	f := newFakeS3()
	body := detailedJPEG(t, 200, 200)
	f.put("shared", origKey("x", "y", "z", "a.jpg"), body, nil)

	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.jpg"), int64(len(body)), "e1")); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.jpg"), int64(len(body)), "e2")); err != nil {
		t.Fatal(err)
	}
	if f.puts != 2 {
		t.Errorf("PutObject called %d times, want 2", f.puts)
	}
}

func TestHandleRejectsBadInput(t *testing.T) {
	tests := []struct {
		name string
		key  string
		body []byte
		size int64
		cfg  func(*config.Config)
	}{
		{name: "oversized declared size", key: origKey("x", "y", "z", "big.jpg"), body: []byte("x"), size: 999 << 20},
		{name: "not an image", key: origKey("x", "y", "z", "a.jpg"), body: []byte("%PDF-1.7 not an image at all")},
		{name: "empty body", key: origKey("x", "y", "z", "a.jpg"), body: []byte{}},
		{
			name: "exceeds pixel limit",
			key:  origKey("x", "y", "z", "a.jpg"),
			body: detailedJPEG(t, 300, 300),
			cfg:  func(c *config.Config) { c.MaxInputPixels = 1000 },
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newFakeS3()
			f.put("shared", tt.key, tt.body, nil)
			size := tt.size
			if size == 0 {
				size = int64(len(tt.body))
			}
			var mutators []func(*config.Config)
			if tt.cfg != nil {
				mutators = append(mutators, tt.cfg)
			}
			h := newHandler(f, mutators...)

			_, err := h.Handle(context.Background(), s3Event("shared", tt.key, size, "e1"))
			if err == nil {
				t.Fatal("expected a validation error")
			}
			var ve *ValidationError
			if !errors.As(err, &ve) {
				t.Errorf("error = %v, want ValidationError", err)
			}
			if f.puts != 0 {
				t.Errorf("PutObject called %d times, want 0", f.puts)
			}
		})
	}
}

func TestHandleMasksOnlyTopHalf(t *testing.T) {
	// 検出処理は使わず上半分固定。下半分は 1 バイトも変わらないこと。
	// PNG は可逆なので画素の完全一致で検証できる。
	f := newFakeS3()
	body := detailedPNG(t, 200, 200)
	f.put("shared", origKey("x", "y", "z", "a.png"), body, nil)

	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(len(body)), "e1")); err != nil {
		t.Fatalf("Handle: %v", err)
	}

	srcImg, _, err := image.Decode(bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	outImg, _, err := image.Decode(bytes.NewReader(f.objects["shared/"+maskedKey("x", "y", "z", "a.png")]))
	if err != nil {
		t.Fatal(err)
	}
	src, out := imaging.ToRGBA(srcImg), imaging.ToRGBA(outImg)

	// 下半分は完全に一致する。
	for y := 100; y < 200; y++ {
		for x := 0; x < 200; x++ {
			if src.RGBAAt(x, y) != out.RGBAAt(x, y) {
				t.Fatalf("bottom half modified at (%d,%d): %v -> %v", x, y, src.RGBAAt(x, y), out.RGBAAt(x, y))
			}
		}
	}

	// 上半分はぼけている。
	top := imaging.Crop(out, image.Rect(0, 0, 200, 100))
	if v := imaging.LaplacianVariance(top); v >= 5.0 {
		t.Errorf("top half not blurred enough: laplacian variance %v", v)
	}
	// 上半分が実際に書き換わっていることも確かめる。
	if imaging.Crop(src, image.Rect(0, 0, 200, 100)).RGBAAt(0, 0) == top.RGBAAt(0, 0) {
		t.Error("top half appears untouched")
	}

	if got := f.meta["shared/"+maskedKey("x", "y", "z", "a.png")]["mask-region"]; got != "top 50% (0,0,200,100)" {
		t.Errorf("mask-region = %q", got)
	}
}

func TestHandleStrengthCheckIgnoresUnmaskedArea(t *testing.T) {
	// 強度検証がマスク領域だけを見ていること。画像全体で測っていると
	// 鮮明な下半分に引きずられ、正常な入力がすべて DLQ に落ちてしまう。
	f := newFakeS3()
	body := detailedPNG(t, 300, 300)
	f.put("shared", origKey("x", "y", "z", "a.png"), body, nil)

	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(len(body)), "e1")); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if f.puts != 1 {
		t.Fatalf("PutObject called %d times, want 1", f.puts)
	}
	whole := imaging.ToRGBA(mustDecode(t, f.objects["shared/"+maskedKey("x", "y", "z", "a.png")]))
	if v := imaging.LaplacianVariance(whole); v <= 5.0 {
		t.Skip("fixture's unmasked half is not detailed enough to exercise this")
	}
}

func TestHandleMaskHeightRatio(t *testing.T) {
	tests := []struct {
		ratio      float64
		wantRegion string
		maskedRows int
	}{
		{0.5, "top 50% (0,0,200,100)", 100},
		{0.25, "top 25% (0,0,200,50)", 50},
		{1.0, "top 100% (0,0,200,200)", 200},
	}
	for _, tt := range tests {
		f := newFakeS3()
		body := detailedPNG(t, 200, 200)
		f.put("shared", origKey("x", "y", "z", "a.png"), body, nil)

		h := newHandler(f, func(c *config.Config) { c.MaskHeightRatio = tt.ratio })
		if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(len(body)), "e1")); err != nil {
			t.Fatalf("ratio %v: %v", tt.ratio, err)
		}
		if got := f.meta["shared/"+maskedKey("x", "y", "z", "a.png")]["mask-region"]; got != tt.wantRegion {
			t.Errorf("ratio %v: mask-region = %q, want %q", tt.ratio, got, tt.wantRegion)
		}

		src := imaging.ToRGBA(mustDecode(t, body))
		out := imaging.ToRGBA(mustDecode(t, f.objects["shared/"+maskedKey("x", "y", "z", "a.png")]))
		// マスク境界の直下は無変更のまま。
		if tt.maskedRows < 200 {
			for x := 0; x < 200; x++ {
				if src.RGBAAt(x, tt.maskedRows) != out.RGBAAt(x, tt.maskedRows) {
					t.Fatalf("ratio %v: row %d should be untouched", tt.ratio, tt.maskedRows)
				}
			}
		}
	}
}

func TestHandleOddHeightRegion(t *testing.T) {
	// 高さが奇数でも領域計算が破綻しないこと。
	f := newFakeS3()
	body := detailedPNG(t, 101, 101)
	f.put("shared", origKey("x", "y", "z", "a.png"), body, nil)

	h := newHandler(f)
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(len(body)), "e1")); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	out := mustDecode(t, f.objects["shared/"+maskedKey("x", "y", "z", "a.png")])
	if w, hh := out.Bounds().Dx(), out.Bounds().Dy(); w != 101 || hh != 101 {
		t.Errorf("output size = %dx%d, want 101x101", w, hh)
	}
}

func mustDecode(t *testing.T, b []byte) image.Image {
	t.Helper()
	img, _, err := image.Decode(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	return img
}

func TestOutputKeyDiffersOnlyByInfix(t *testing.T) {
	// 原本とマスク済みは infix だけが違う。それ以外の変数は共通。
	l := testConfig().Layout()
	p := s3key.Parts{X: "tenant-a", Y: "2026-09", Z: "front", N: "日本語 ファイル.jpg"}

	orig, err := l.Original(p)
	if err != nil {
		t.Fatal(err)
	}
	masked, err := l.Masked(p)
	if err != nil {
		t.Fatal(err)
	}
	if want := "masking/tenant-a/2026-09/original/front/日本語 ファイル.jpg"; orig != want {
		t.Errorf("Original = %q, want %q", orig, want)
	}
	if want := "masking/tenant-a/2026-09/v1/front/日本語 ファイル.jpg"; masked != want {
		t.Errorf("Masked = %q, want %q", masked, want)
	}
}

func TestHandleDecodesEncodedKeys(t *testing.T) {
	// S3 通知のキーはフォームエンコード。"+" はスペースを表す。
	f := newFakeS3()
	body := detailedJPEG(t, 200, 200)
	f.put("shared", origKey("x", "y", "z", "my photo.jpg"), body, nil)

	h := newHandler(f)
	ev := payload(events.S3Event{Records: []events.S3EventRecord{{
		S3: events.S3Entity{
			Bucket: events.S3Bucket{Name: "shared"},
			Object: events.S3Object{Key: "masking/x/y/original/z/my+photo.jpg", Size: int64(len(body)), ETag: "e1"},
		},
	}}})
	if _, err := h.Handle(context.Background(), ev); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if _, ok := f.objects["shared/"+maskedKey("x", "y", "z", "my photo.jpg")]; !ok {
		t.Errorf("output not written; objects = %v", keys(f.objects))
	}
}

func TestHandlePropagatesTransientErrorsForRetry(t *testing.T) {
	f := newFakeS3()
	f.put("shared", origKey("x", "y", "z", "a.jpg"), detailedJPEG(t, 100, 100), nil)
	f.getErr = errors.New("SlowDown: please reduce your request rate")

	h := newHandler(f)
	_, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.jpg"), 100, "e1"))
	if err == nil {
		t.Fatal("expected an error so Lambda retries")
	}
	var ve *ValidationError
	if errors.As(err, &ve) {
		t.Error("transient failure must not be classified as a validation error")
	}
}

func TestHandleWithDownscaleHardening(t *testing.T) {
	f := newFakeS3()
	body := detailedJPEG(t, 400, 300)
	f.put("shared", origKey("x", "y", "z", "a.jpg"), body, nil)

	h := newHandler(f, func(c *config.Config) { c.DownscaleFactor = 8 })
	if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.jpg"), int64(len(body)), "e1")); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	meta := f.meta["shared/"+maskedKey("x", "y", "z", "a.jpg")]
	if meta["downscale-factor"] != "8" {
		t.Errorf("downscale-factor = %q, want 8", meta["downscale-factor"])
	}
	out, _, err := image.Decode(bytes.NewReader(f.objects["shared/"+maskedKey("x", "y", "z", "a.jpg")]))
	if err != nil {
		t.Fatal(err)
	}
	if w, h := out.Bounds().Dx(), out.Bounds().Dy(); w != 400 || h != 300 {
		t.Errorf("output size = %dx%d, want 400x300", w, h)
	}
}

func TestStrengthCheckCatchesLocalUnmaskedArea(t *testing.T) {
	// 領域全体の平均で判定すると、小さな素通し部分が広い平坦な背景に薄められて
	// 検知できない。区画ごとの最悪値で見ていることの回帰テスト。
	//
	// 模様のコントラストは、平均では旧方式のしきい値を下回るが区画単位では
	// 大きく超える水準に調整してある（引きの写真で顔だけが残る状況に相当）。
	f := newFakeS3()

	const (
		size  = 480
		amp   = 4  // 素通し部分のコントラスト
		patch = 64 // 区画 1 つ分
	)
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			img.Set(x, y, color.RGBA{128, 128, 128, 255})
		}
	}
	for y := 60; y < 60+patch; y++ {
		for x := 60; x < 60+patch; x++ {
			c := color.RGBA{128 + amp, 128 + amp, 128 + amp, 255}
			if (x/2)%2 == 0 {
				c = color.RGBA{128 - amp, 128 - amp, 128 - amp, 255}
			}
			img.Set(x, y, c)
		}
	}

	// 前提の確認: 領域全体の平均ではしきい値を下回る＝旧方式なら見逃していた。
	region := imaging.Crop(img, imaging.TopRegion(size, size, 0.5))
	if mean := imaging.LaplacianVariance(region); mean >= testConfig().MaxLaplacianVar {
		t.Fatalf("fixture の平均 %v がしきい値を超えている。これでは旧方式でも検知できてしまい回帰テストにならない", mean)
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	f.put("shared", origKey("x", "y", "z", "a.png"), buf.Bytes(), nil)

	// ぼかしも縮小も実質無効にして、素通しの一角を残す。
	h := newHandler(f, func(c *config.Config) {
		c.BlurRatio = 0.0001
		c.MinBlurRadiusPx = 0.1
		c.DownscaleFactor = 1
	})
	_, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(buf.Len()), "e1"))

	var se *StrengthError
	if !errors.As(err, &se) {
		t.Fatalf("error = %v, want StrengthError（素通しの一角が平均に埋もれて見逃されている）", err)
	}
	if f.puts != 0 {
		t.Errorf("PutObject called %d times, want 0", f.puts)
	}
}

func TestDownscaleNeverTouchesAreaOutsideMask(t *testing.T) {
	// 縮小は切り出したマスク領域の中だけに掛かり、画像全体には掛からない。
	// 領域外が 1 画素でも変われば、マスク以外に影響が出ているということ。
	// PNG は可逆なので画素の完全一致で検証できる。
	for _, factor := range []int{1, 4, 8, 16} {
		f := newFakeS3()
		body := detailedPNG(t, 240, 240)
		f.put("shared", origKey("x", "y", "z", "a.png"), body, nil)

		h := newHandler(f, func(c *config.Config) { c.DownscaleFactor = factor })
		if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(len(body)), "e1")); err != nil {
			t.Fatalf("factor %d: %v", factor, err)
		}

		src := imaging.ToRGBA(mustDecode(t, body))
		out := imaging.ToRGBA(mustDecode(t, f.objects["shared/"+maskedKey("x", "y", "z", "a.png")]))
		for y := 120; y < 240; y++ {
			for x := 0; x < 240; x++ {
				if src.RGBAAt(x, y) != out.RGBAAt(x, y) {
					t.Fatalf("factor %d: pixel outside the mask changed at (%d,%d)", factor, x, y)
				}
			}
		}
	}
}

func TestBlurPassesDoNotAffectAreaOutsideMask(t *testing.T) {
	// パス数を変えても領域外には影響しない。
	for _, passes := range []int{2, 3, 5} {
		f := newFakeS3()
		body := detailedPNG(t, 240, 240)
		f.put("shared", origKey("x", "y", "z", "a.png"), body, nil)

		h := newHandler(f, func(c *config.Config) { c.BlurPasses = passes })
		if _, err := h.Handle(context.Background(), s3Event("shared", origKey("x", "y", "z", "a.png"), int64(len(body)), "e1")); err != nil {
			t.Fatalf("passes %d: %v", passes, err)
		}

		src := imaging.ToRGBA(mustDecode(t, body))
		out := imaging.ToRGBA(mustDecode(t, f.objects["shared/"+maskedKey("x", "y", "z", "a.png")]))
		for y := 120; y < 240; y++ {
			for x := 0; x < 240; x++ {
				if src.RGBAAt(x, y) != out.RGBAAt(x, y) {
					t.Fatalf("passes %d: pixel outside the mask changed at (%d,%d)", passes, x, y)
				}
			}
		}
		if v := imaging.LaplacianVariance(imaging.Crop(out, image.Rect(0, 0, 240, 120))); v >= 5.0 {
			t.Errorf("passes %d: mask region not blurred enough (variance %v)", passes, v)
		}
	}
}

// withFakeEXIF は JPEG の SOI 直後に Orientation=1 だけを持つ APP1 セグメントを挿入する。
func withFakeEXIF(jpg []byte) []byte {
	tiff := []byte{
		'I', 'I', 42, 0, // リトルエンディアン, マジック
		8, 0, 0, 0, // IFD0 オフセット
		1, 0, // エントリ数
		0x12, 0x01, // タグ 0x0112 Orientation
		3, 0, // SHORT
		1, 0, 0, 0, // count
		1, 0, 0, 0, // 値 = 1
		0, 0, 0, 0, // 次 IFD なし
	}
	payload := append([]byte("Exif\x00\x00"), tiff...)
	segLen := len(payload) + 2
	seg := append([]byte{0xFF, 0xE1, byte(segLen >> 8), byte(segLen)}, payload...)

	out := make([]byte, 0, len(jpg)+len(seg))
	out = append(out, jpg[:2]...) // SOI
	out = append(out, seg...)
	return append(out, jpg[2:]...)
}

func keys(m map[string][]byte) []string {
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}

var _ = strings.TrimPrefix

// --- リクエスト起動 ---

func TestHandleRequestMasksTheKeyBuiltFromVariables(t *testing.T) {
	f := newFakeS3()
	body := detailedJPEG(t, 400, 300)
	f.put("shared", origKey("tenant-a", "2026-09", "front", "id.jpg"), body, map[string]string{})

	h := newHandler(f)
	res, err := h.Handle(context.Background(), request("tenant-a", "2026-09", "front", "id.jpg"))
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if res == nil {
		t.Fatal("response is nil")
	}
	if want := origKey("tenant-a", "2026-09", "front", "id.jpg"); res.SourceKey != want {
		t.Errorf("SourceKey = %q, want %q", res.SourceKey, want)
	}
	if want := maskedKey("tenant-a", "2026-09", "front", "id.jpg"); res.OutputKey != want {
		t.Errorf("OutputKey = %q, want %q", res.OutputKey, want)
	}
	if res.Skipped {
		t.Error("Skipped = true, want false")
	}
	if _, ok := f.objects["shared/"+maskedKey("tenant-a", "2026-09", "front", "id.jpg")]; !ok {
		t.Errorf("output not written; objects = %v", keys(f.objects))
	}
}

func TestHandleRequestIsIdempotent(t *testing.T) {
	f := newFakeS3()
	body := detailedJPEG(t, 200, 200)
	f.put("shared", origKey("x", "y", "z", "a.jpg"), body, nil)

	h := newHandler(f)
	for i := 0; i < 2; i++ {
		res, err := h.Handle(context.Background(), request("x", "y", "z", "a.jpg"))
		if err != nil {
			t.Fatalf("Handle #%d: %v", i+1, err)
		}
		if want := i == 1; res.Skipped != want {
			t.Errorf("#%d: Skipped = %v, want %v", i+1, res.Skipped, want)
		}
	}
	if f.puts != 1 {
		t.Errorf("PutObject called %d times, want 1", f.puts)
	}
}

func TestHandleRequestRejectsMissingObject(t *testing.T) {
	f := newFakeS3()
	h := newHandler(f)

	_, err := h.Handle(context.Background(), request("x", "y", "z", "missing.jpg"))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("error = %v, want ValidationError", err)
	}
	if f.puts != 0 {
		t.Errorf("PutObject called %d times, want 0", f.puts)
	}
}

func TestHandleRequestRejectsInjectedVariables(t *testing.T) {
	// 変数は呼び出し側から来る。キーを別の場所へ向ける細工を通さないこと。
	tests := []struct {
		name       string
		x, y, z, n string
	}{
		{"スラッシュで階層を増やす", "a/b", "y", "z", "n.jpg"},
		{"上の階層を指す", "..", "y", "z", "n.jpg"},
		{"infix を差し替える", "x", "y", "z", "../v1/z/n.jpg"},
		{"空の変数", "", "y", "z", "n.jpg"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newFakeS3()
			h := newHandler(f)

			_, err := h.Handle(context.Background(), request(tt.x, tt.y, tt.z, tt.n))
			var ve *ValidationError
			if !errors.As(err, &ve) {
				t.Errorf("error = %v, want ValidationError", err)
			}
			if f.gets != 0 || f.puts != 0 {
				t.Errorf("S3 was touched: gets=%d puts=%d", f.gets, f.puts)
			}
		})
	}
}

func TestHandleRejectsUnknownPayload(t *testing.T) {
	h := newHandler(newFakeS3())
	for _, p := range []json.RawMessage{
		payload(map[string]string{"foo": "bar"}),
		payload(map[string]any{"Records": []any{}}),
		json.RawMessage(`{`),
	} {
		if _, err := h.Handle(context.Background(), p); err == nil {
			t.Errorf("Handle(%s) should fail", p)
		}
	}
}

func TestHandleSkipsKeysOutsideTheLayout(t *testing.T) {
	// レイアウトに合わないキーは処理対象外。エラーではなくスキップ。
	f := newFakeS3()
	h := newHandler(f)
	for _, key := range []string{
		"masking/x/y/original/z/sub/a.jpg", // 階層が多い
		"masking/x/y/original/a.jpg",       // 階層が足りない
		"other/x/y/original/z/a.jpg",       // プレフィックスが違う
	} {
		if _, err := h.Handle(context.Background(), s3Event("shared", key, 100, "e1")); err != nil {
			t.Errorf("Handle(%q) = %v, want nil (skip)", key, err)
		}
	}
	if f.gets != 0 || f.puts != 0 {
		t.Errorf("S3 was touched: gets=%d puts=%d", f.gets, f.puts)
	}
}
