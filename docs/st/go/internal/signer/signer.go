// Package signer はチケットコードに署名し、view / QR エンドポイントがこの API の発行した URL だけを返すようにする。
// クリーンアーキテクチャ: HTTP 層が使うアプリケーションルール(発行フローとは別)。
package signer

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
)

const sigLength = 22

type Signer struct {
	keys [][]byte // keys[0] で署名し、すべてのキーで検証する(ローテーション)
}

// New は現在のソルトと、ローテーション中は以前のソルトを受け取る。
func New(current, previous string) (*Signer, error) {
	if current == "" {
		return nil, errors.New("signing salt is empty")
	}
	keys := [][]byte{[]byte(current)}
	if previous != "" {
		keys = append(keys, []byte(previous))
	}
	return &Signer{keys: keys}, nil
}

func (s *Signer) Sign(ticketCode string) string {
	return sign(s.keys[0], ticketCode)
}

func (s *Signer) Verify(ticketCode, sig string) bool {
	if len(sig) != sigLength {
		return false
	}
	for _, k := range s.keys {
		if hmac.Equal([]byte(sign(k, ticketCode)), []byte(sig)) {
			return true
		}
	}
	return false
}

func sign(key []byte, ticketCode string) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(ticketCode))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))[:sigLength]
}
