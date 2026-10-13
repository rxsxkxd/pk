package main

import (
	"flag"
	"io"
	"log"
	"net/http"
	"os"

	"ticketqr/internal/httpapi"
	"ticketqr/internal/localhttp"
)

// runLocal はローカル開発用にハンドラを素の HTTP で提供する(localhttp を参照)。
func runLocal() {
	addr := flag.String("addr", ":8080", "listen address")
	flag.Parse()

	setDefault("APP_ENV", "local")
	setDefault("PUBLIC_BASE_URL", "http://localhost"+*addr)
	setDefault("SIGNING_SALT", "local-dev-salt")
	setDefault("ANALYZER_MODE", "mock")
	setDefault("TICKET_CODE_SUFFIX", "LOCAL")

	h := mustNewHandlers()
	mux := http.NewServeMux()
	// API Gateway のルートキーはそのまま ServeMux のパターンとして有効なので、どちらも同じようにルーティングされる。
	for _, key := range httpapi.RouteKeys {
		mux.Handle(key, localhttp.Adapt(key, h.Route))
	}
	mux.HandleFunc("GET /{$}", uploadForm)

	log.Printf("listening on %s (open http://localhost%s/)", *addr, *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

func setDefault(key, value string) {
	if os.Getenv(key) == "" {
		os.Setenv(key, value)
	}
}

// uploadForm はパターン A と B-1 を呼ぶクライアントページの代わり。ローカルにのみ存在する。
func uploadForm(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, `<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>ローカル動作確認</title></head>
<body>
  <h1>パターンA 動作確認（fetch + FormData → JSON）</h1>
  <form id="inline">
    <input type="file" name="image" accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp" required>
    <button type="submit">発行</button>
  </form>
  <p id="inline-result"></p>
  <img id="inline-qr" alt="">

  <h1>パターンB-1 動作確認（フォーム送信 → 303）</h1>
  <form method="post" action="/v1/tickets" enctype="multipart/form-data">
    <input type="file" name="image" accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp" required>
    <button type="submit">発行</button>
  </form>

  <script>
    document.getElementById("inline").addEventListener("submit", async (e) => {
      e.preventDefault();
      const res = await fetch("/v1/tickets/qr-inline", { method: "POST", body: new FormData(e.target) });
      const body = await res.json();
      document.getElementById("inline-result").textContent = res.ok ? body.ticketCode : res.status + " " + body.error.code;
      document.getElementById("inline-qr").src = res.ok ? "data:" + body.qr.mimeType + ";base64," + body.qr.data : "";
    });
  </script>
</body>
</html>
`)
}
