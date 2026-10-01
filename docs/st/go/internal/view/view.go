// Package view renders the shared HTML templates.
package view

import (
	"bytes"
	"html/template"

	"ticketqr/templates"
)

type Renderer struct {
	ticket *template.Template
	errorT *template.Template
}

func New() (*Renderer, error) {
	ticket, err := template.ParseFS(templates.FS, "ticket.html")
	if err != nil {
		return nil, err
	}
	errorT, err := template.ParseFS(templates.FS, "error.html")
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
