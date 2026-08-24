package phase

import "testing"

// tests/migration_phase_test.sh（scripts/lib/migration_phase.rb）と同じ組み合わせ。
// 2 つの実装が同じ判定をすることを、同じ表で固定する。
func TestResolve(t *testing.T) {
	const (
		sourceVersion = "8.0"
		sourceGroup   = "svc-prod-mysql80-v1"
		targetVersion = "8.4.10"
		targetGroup   = "svc-prod-mysql84-v1"
	)
	for _, tc := range []struct {
		name, version, group, want string
	}{
		{"移行前（宣言どおり）", "8.0.44", sourceGroup, Pre},
		{"移行後（宣言どおり）", "8.4.10", targetGroup, Post},
		{"移行前・自動パッチ更新後", "8.0.46", sourceGroup, Pre},
		{"移行後・自動パッチ更新後", "8.4.11", targetGroup, Post},
		{"移行後・パッチが下位", "8.4.9", targetGroup, Post},
		{"バージョンだけ移行後", "8.4.10", sourceGroup, Unknown},
		{"パラメータグループだけ移行後", "8.0.44", targetGroup, Unknown},
		{"想定外のバージョン", "5.7.44", sourceGroup, Unknown},
		{"想定外のパラメータグループ", "8.0.44", "default.mysql8.0", Unknown},
		{"空のパラメータグループ", "8.0.44", "", Unknown},
		{"8.04 は 8.0 と区別される", "8.04.0", sourceGroup, Unknown},
	} {
		if got := Resolve(tc.version, tc.group, sourceVersion, sourceGroup, targetVersion, targetGroup); got != tc.want {
			t.Errorf("%s: %s（期待 %s）", tc.name, got, tc.want)
		}
	}
}

func TestMajorMinor(t *testing.T) {
	for input, want := range map[string]string{
		"8.0.44": "8.0", "8.4.10": "8.4", "8.0": "8.0", "8": "8", "8.04.0": "8.04", "": "",
	} {
		if got := MajorMinor(input); got != want {
			t.Errorf("MajorMinor(%q) = %q（期待 %q）", input, got, want)
		}
	}
}
