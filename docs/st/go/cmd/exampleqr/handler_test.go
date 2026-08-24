package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"image"
	_ "image/png"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/makiuchi-d/gozxing"
	qrreader "github.com/makiuchi-d/gozxing/qrcode"
)

func TestHandle(t *testing.T) {
	res, err := handle(context.Background(), events.APIGatewayV2HTTPRequest{RouteKey: routeKey})
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != 200 || res.Headers["Content-Type"] != "image/png" || !res.IsBase64Encoded {
		t.Fatalf("got %d %q base64=%v", res.StatusCode, res.Headers["Content-Type"], res.IsBase64Encoded)
	}
	if res.Headers["Cache-Control"] != "no-store" {
		t.Errorf("Cache-Control = %q", res.Headers["Cache-Control"])
	}

	data, err := base64.StdEncoding.DecodeString(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	bmp, err := gozxing.NewBinaryBitmapFromImage(img)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := qrreader.NewQRCodeReader().Decode(bmp, nil)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.GetText() != "https://example.com" {
		t.Errorf("decoded %q", decoded.GetText())
	}
}
