// Package imageinput detects the format of an uploaded image. This is a technical concern of the HTTP
// layer; which formats are accepted is a business rule decided in usecase.
package imageinput

import (
	"bytes"
	"errors"
	"image"
	"image/jpeg"
	"image/png"
	"io"

	"github.com/gabriel-vasile/mimetype"
	"go4.org/media/heif"
	"golang.org/x/image/webp"
)

// MaxBytes is the upload limit set by the runtime: a Lambda request is at most 6MB and API Gateway
// base64-encodes binary bodies (×4/3).
const MaxBytes = 4 << 20

// validators confirm that data of a detected type really is that image, by parsing its header up to the
// image size. Types without a validator (including HEIF image sequences) are not recognized.
var validators = map[string]func([]byte) error{
	"image/jpeg": config(jpeg.DecodeConfig),
	"image/png":  config(png.DecodeConfig),
	"image/webp": config(webp.DecodeConfig),
	"image/heic": heifSize,
	"image/heif": heifSize,
	"image/avif": heifSize,
}

// Detect returns the MIME type of data, or "" when it is not a recognizable image. mimetype tells the
// format from the leading bytes; the format's own parser then reads up to the image size, so bytes that
// only start like an image are rejected (as image-size does in the Node version).
func Detect(data []byte) string {
	mt := mimetype.Detect(data).String()
	if validate, ok := validators[mt]; ok && validate(data) == nil {
		return mt
	}
	return ""
}

// config adapts an image.DecodeConfig function to a validator.
func config(decode func(io.Reader) (image.Config, error)) func([]byte) error {
	return func(data []byte) error {
		_, err := decode(bytes.NewReader(data))
		return err
	}
}

var errNoSize = errors.New("heif: no image size")

// heifSize requires the HEIF container's primary item to have its size (ispe). Only the metadata boxes
// are read; the image itself is not decoded.
func heifSize(data []byte) error {
	item, err := heif.Open(bytes.NewReader(data)).PrimaryItem()
	if err != nil {
		return err
	}
	if _, _, ok := item.SpatialExtents(); !ok {
		return errNoSize
	}
	return nil
}
