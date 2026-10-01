// Package signer signs ticket codes so the view / QR endpoints only serve URLs this API issued.
package signer

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
)

const sigLength = 22

type Signer struct {
	keys [][]byte // keys[0] signs; all keys verify (rotation)
}

// New takes the current salt and, during rotation, the previous one.
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
