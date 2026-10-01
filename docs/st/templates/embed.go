// Package templates embeds the HTML views shared by the Go and Node implementations.
package templates

import "embed"

//go:embed *.html
var FS embed.FS
