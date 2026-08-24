// Package metrics は CloudWatch Embedded Metric Format (EMF) でメトリクスを出す。
// ログに書くだけで CloudWatch のカスタムメトリクスになるため、
// PutMetricData の API 呼び出しも追加の IAM 権限も不要。
package metrics

import (
	"encoding/json"
	"os"
	"time"
)

// Namespace は本アプリのメトリクス名前空間。template.yaml のアラームと一致させる。
const Namespace = "ImageMask"

// Metric は 1 つのメトリクス値。
type Metric struct {
	Name  string
	Unit  string // Count / Milliseconds / Bytes / None
	Value float64
}

var out = os.Stdout

// Emit は EMF 形式の 1 行を標準出力へ書く。失敗しても処理は止めない。
func Emit(metrics ...Metric) {
	defs := make([]map[string]string, 0, len(metrics))
	rec := map[string]any{}
	for _, m := range metrics {
		defs = append(defs, map[string]string{"Name": m.Name, "Unit": m.Unit})
		rec[m.Name] = m.Value
	}
	rec["_aws"] = map[string]any{
		"Timestamp": time.Now().UnixMilli(),
		"CloudWatchMetrics": []map[string]any{{
			"Namespace":  Namespace,
			"Dimensions": []([]string){{}}, // ディメンションなし（関数単位で集計）
			"Metrics":    defs,
		}},
	}
	b, err := json.Marshal(rec)
	if err != nil {
		return
	}
	out.Write(append(b, '\n'))
}

// Count は件数メトリクスの短縮形。
func Count(name string, v float64) Metric {
	return Metric{Name: name, Unit: "Count", Value: v}
}
