package deployconfig

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "c.yml")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestReadsLikeTheRubyReader(t *testing.T) {
	config, err := Load(write(t, `
aws_region: ap-northeast-1
services:
  svc:
    source_db_instance_identifier: blue
    actions:
      cleanup: approved
      switchover_timeout: 600
    empty: ""
`))
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := config.Required("aws_region"); v != "ap-northeast-1" {
		t.Errorf("aws_region: %q", v)
	}
	if v := config.Optional("aws_profile", ""); v != "" {
		t.Errorf("aws_profile: %q", v)
	}
	svc, err := config.Service("svc")
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{"actions.cleanup": "approved", "actions.switchover_timeout": "600"} {
		if v, _ := svc.Required(key); v != want {
			t.Errorf("%s: %q（期待 %q）", key, v, want)
		}
	}
	if v := svc.Optional("actions.build", "pending"); v != "pending" {
		t.Errorf("既定値へ倒すこと: %q", v)
	}
	for key, want := range map[string]string{
		"absent": "services.svc.absent が未定義である",
		"empty":  "services.svc.empty が未定義である",
	} {
		if _, err := svc.Required(key); err == nil || err.Error() != want {
			t.Errorf("%s: %v（期待 %q）", key, err, want)
		}
	}
	if _, err := config.Service("nosuch"); err == nil || err.Error() != "services.nosuch が未定義である" {
		t.Errorf("未知のサービス: %v", err)
	}
	if _, err := Load(filepath.Join(t.TempDir(), "absent.yml")); err == nil || !strings.Contains(err.Error(), "YAML を読み込めなかった") {
		t.Errorf("読めないファイル: %v", err)
	}
}
