package common

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteAtomicCreatesReadableFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "out.json")
	if err := WriteJSON(path, map[string]string{"key": "value"}); err != nil {
		t.Fatalf("WriteJSON: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	// CreateTemp の 0600 をそのまま残すと、生成物を人も CI も読めない。
	if got := info.Mode().Perm(); got != 0o644 {
		t.Errorf("permission = %04o, want 0644", got)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if want := "{\n  \"key\": \"value\"\n}\n"; string(content) != want {
		t.Errorf("content = %q, want %q", content, want)
	}
}

func TestWriteAtomicLeavesNoFileOnFailure(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "out.json")
	// 既存ファイルを壊さないことも併せて確かめる。
	if err := os.WriteFile(path, []byte("original\n"), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	err := WriteAtomic(path, func(*os.File) error { return os.ErrInvalid })
	if err == nil {
		t.Fatal("WriteAtomic succeeded, want failure")
	}

	content, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("ReadFile: %v", readErr)
	}
	if string(content) != "original\n" {
		t.Errorf("existing file was modified: %q", content)
	}

	// 一時ファイルを残さない。
	entries, readErr := os.ReadDir(directory)
	if readErr != nil {
		t.Fatalf("ReadDir: %v", readErr)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".out.json.") {
			t.Errorf("temporary file left behind: %s", entry.Name())
		}
	}
}

func TestSortedKeysIsDeterministic(t *testing.T) {
	got := SortedKeys(map[string]int{"zeta": 1, "alpha": 2, "mid": 3})
	want := []string{"alpha", "mid", "zeta"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("SortedKeys = %v, want %v", got, want)
	}
}
