package ticket

import (
	"context"
	"errors"
)

// Verifier は証明書画像が本物で受け付け可能かを検証サーバに問い合わせる。
// 使う側であるここで定義し、package analyzer が実装する(プロセス内のモックと、画像解析サーバの
// HTTP クライアント)。
type Verifier interface {
	Verify(ctx context.Context, img CertificateImage) (Verdict, error)
}

// Result は検証器の判定: 画像解析サーバのレスポンスの "result"。API はレスポンスの
// それ以外の部分を見ない。
type Result string

const (
	ResultPass   Result = "PASS"   // チケットを付与する
	ResultReject Result = "REJECT" // 使える証明書画像ではない: ErrCertificateRejected
	ResultRetry  Result = "RETRY"  // この画像では判定できなかった。撮り直してもらう: ErrCertificateRetry
)

// Verdict は検証器の回答。
type Verdict struct {
	Result Result
}

// VerifyAndGrant がタイムアウトとその他の失敗を区別できるよう、Verifier がラップして返すエラー。
var (
	ErrVerifierUpstream = errors.New("verifier upstream error")
	ErrVerifierTimeout  = errors.New("verifier timeout")
)
