// Package phase は、移行元インスタンスの実状態から移行のどの地点にいるかを判定する。
//
// scripts/lib/migration_phase.rb（CI から到達する側）と**同じ判定**を tools/ 側で持つ。
// scripts/ と tools/ はコードを共有しない方針のため複製しており、
// 判定を変えるときは両方を直す（tools/internal/phase/phase_test.go のテーブルは
// tests/migration_phase_test.sh と同じ組み合わせを検査する）。
//
// 判定の根拠:
//
//	切替時に RDS は blue を <name>-old1 へリネームし、green が <name> を引き継ぐ。
//	このため source_db_instance_identifier が指す実体は、切替の前後で
//	「8.0 + 旧パラメータグループ」から「8.4 + 新パラメータグループ」へ変わる。
//	Deployment が削除された後も判定できる。
package phase

import (
	"fmt"
	"strings"
)

const (
	Pre     = "pre_switchover"
	Post    = "post_switchover"
	Unknown = "unknown"
)

// MajorMinor はエンジンバージョンから major.minor だけを取り出す。
// 8.0.44 -> 8.0 / 8.4.10 -> 8.4 / 8.0 -> 8.0 / 8 -> 8 / 8.04.0 -> 8.04
func MajorMinor(version string) string {
	parts := strings.Split(version, ".")
	if len(parts) > 2 {
		parts = parts[:2]
	}
	return strings.Join(parts, ".")
}

// Resolve は pre_switchover / post_switchover / unknown を返す。
// エンジンバージョンは major.minor に正規化して比較し（自動マイナーアップグレードに追随する）、
// パラメータグループ名は厳密一致とする。
func Resolve(currentVersion, currentGroup, sourceVersion, sourceGroup, targetVersion, targetGroup string) string {
	current := MajorMinor(currentVersion)
	switch {
	case current == MajorMinor(sourceVersion) && currentGroup == sourceGroup:
		return Pre
	case current == MajorMinor(targetVersion) && currentGroup == targetGroup:
		return Post
	default:
		return Unknown
	}
}

// Describe は判定に使った実測値と宣言値を、人が読める形で返す（unknown の説明用）。
func Describe(currentVersion, currentGroup, sourceVersion, sourceGroup, targetVersion, targetGroup string) string {
	return fmt.Sprintf("  実測: engine=%s parameter_group=%s\n"+
		"  移行元の宣言: engine=%s* parameter_group=%s\n"+
		"  移行先の宣言: engine=%s* parameter_group=%s",
		currentVersion, currentGroup, sourceVersion, sourceGroup, targetVersion, targetGroup)
}
