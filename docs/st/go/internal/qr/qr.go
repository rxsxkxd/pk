// Package qr はチケットコードを QR の PNG 画像として描画する。クリーンアーキテクチャ: ドライバ(QR ライブラリを
// ラップする)で、チケット API(httpapi)と example.com の QR エンドポイント(cmd/exampleqr)が共有する。
package qr

import qrcode "github.com/skip2/go-qrcode"

const size = 256

// PNG は content を誤り訂正レベル M、4 モジュールのクワイエットゾーン(ライブラリのデフォルト)で描画する。
func PNG(content string) ([]byte, error) {
	return qrcode.Encode(content, qrcode.Medium, size)
}
