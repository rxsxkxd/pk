package config

import (
	"strings"
	"testing"
)

func TestLoadRejectsWeakMaskSettings(t *testing.T) {
	// マスクの強さは設定で担保する。弱すぎる設定は起動時に止め、
	// 不十分な画像を出力してから検査で拾う形にしない（設計書 §12.6）。
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{
			name: "ぼかしが許容ラインを下回る",
			env:  map[string]string{"MIN_BLUR_RATIO": "0.001"},
			want: "MIN_BLUR_RATIO",
		},
		{
			name: "ぼかしが無効",
			env:  map[string]string{"MIN_BLUR_RATIO": "0"},
			want: "MIN_BLUR_RATIO",
		},
		{
			name: "マスク範囲が空",
			env:  map[string]string{"MASK_HEIGHT_RATIO": "0"},
			want: "MASK_HEIGHT_RATIO",
		},
		{
			name: "マスク範囲が画像を超える",
			env:  map[string]string{"MASK_HEIGHT_RATIO": "1.5"},
			want: "MASK_HEIGHT_RATIO",
		},
		{
			name: "ぼかしのパスが 1 回",
			env:  map[string]string{"BLUR_PASSES": "1"},
			want: "BLUR_PASSES",
		},
		{
			name: "検査の区画が小さすぎる",
			env:  map[string]string{"STRENGTH_BLOCK_PX": "8"},
			want: "STRENGTH_BLOCK_PX",
		},
		{
			name: "出力先が未設定",
			env:  map[string]string{"OUTPUT_BUCKET": ""},
			want: "OUTPUT_BUCKET",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("OUTPUT_BUCKET", "masked")
			for k, v := range tt.env {
				t.Setenv(k, v)
			}
			_, err := Load()
			if err == nil {
				t.Fatalf("expected an error mentioning %s", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %q, want it to mention %s", err, tt.want)
			}
		})
	}
}

func TestLoadAcceptsTheAcceptanceLine(t *testing.T) {
	// 許容ラインちょうどは通る。
	t.Setenv("OUTPUT_BUCKET", "masked")
	t.Setenv("MIN_BLUR_RATIO", "0.004")

	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.BlurRatio != MinAllowedBlurRatio {
		t.Errorf("BlurRatio = %v, want %v", c.BlurRatio, MinAllowedBlurRatio)
	}
}

func TestLoadDefaults(t *testing.T) {
	t.Setenv("OUTPUT_BUCKET", "masked")

	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	checks := []struct {
		name string
		got  any
		want any
	}{
		{"MaskHeightRatio", c.MaskHeightRatio, 0.5},
		{"BlurRatio", c.BlurRatio, 0.04},
		{"MinBlurRadiusPx", c.MinBlurRadiusPx, 8.0},
		{"BlurPasses", c.BlurPasses, 2},
		{"DownscaleFactor", c.DownscaleFactor, 4},
		{"StrengthBlockPx", c.StrengthBlockPx, 64},
		{"MaxLaplacianVar", c.MaxLaplacianVar, 15.0},
	}
	for _, ch := range checks {
		if ch.got != ch.want {
			t.Errorf("%s = %v, want %v", ch.name, ch.got, ch.want)
		}
	}
	// 既定のぼかしは許容ラインに対して十分な余裕があること。
	if c.BlurRatio < MinAllowedBlurRatio*5 {
		t.Errorf("既定の BlurRatio %v が許容ライン %v に近すぎる", c.BlurRatio, MinAllowedBlurRatio)
	}
}
