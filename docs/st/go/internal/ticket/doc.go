// Package ticket はチケット QR API の中核(クリーンアーキテクチャ: エンティティとユースケース):
// チケットコードのルール、VerifyAndGrant(証明書画像を検証してからチケットを付与する)、ビジネス
// エラー。自身では I/O を行わず、他の internal パッケージにも依存しない。検証サーバには、ここで
// 定義し package analyzer が実装する Verifier インタフェースを通じてアクセスする。
package ticket
