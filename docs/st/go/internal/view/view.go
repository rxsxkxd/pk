// Package view は Go 版の HTML ビュー(templates/*.html、バイナリに埋め込み)を描画する。
// Node 版は同じページを hono/html で組み立てる。ファイルは共有しない(NODE.md 5.3)。
// クリーンアーキテクチャ: インバウンドアダプタ(プレゼンテーション)の一部で、package httpapi が使う。
package view

import (
	"bytes"
	"embed"
	"html/template"
)

//go:embed templates/*.html
var files embed.FS

type Renderer struct {
	ticket *template.Template
	errorT *template.Template
}

func New() (*Renderer, error) {
	ticket, err := template.ParseFS(files, "templates/ticket.html")
	if err != nil {
		return nil, err
	}
	errorT, err := template.ParseFS(files, "templates/error.html")
	if err != nil {
		return nil, err
	}
	return &Renderer{ticket: ticket, errorT: errorT}, nil
}

func (r *Renderer) Ticket(ticketCode, qrURL string) ([]byte, error) {
	return render(r.ticket, struct {
		TicketCode string
		QRURL      string
	}{ticketCode, qrURL})
}

func (r *Renderer) Error(code, message string) ([]byte, error) {
	return render(r.errorT, struct {
		Code    string
		Message string
	}{code, message})
}

func render(t *template.Template, data any) ([]byte, error) {
	var buf bytes.Buffer
	if err := t.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
