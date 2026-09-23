// collect_green_state は Step 4 の検証に必要な AWS の状態を集め、
// 判定器（generate_green_verification_report --input-dir）が読むファイル一式を書き出す。
//
// **収集だけを行う。判定はしない。**ロジックは scripts/internal/greenstate にある。
//
// 標準出力には、呼び出し側（verify_green.sh）が続きで使う値を KEY=値 の行で出す。
// 呼び出し側は変数へ受けてから eval する（eval "$(...)" と書くと失敗をすり抜けるため）。
//
//	DEPLOYMENT_ID      引き当てた Blue/Green Deployment の識別子
//	GREEN_INSTANCE_ID  Green の DB インスタンス識別子
//	GREEN_ENDPOINT     Green のエンドポイント（実効値収集が接続する先）
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"rds-mysql-upgrade/scripts/internal/greenstate"
)

func main() {
	region := flag.String("region", "", "AWS リージョン（必須）")
	profile := flag.String("profile", "", "AWS CLI の named profile（省略可）")
	sourceID := flag.String("source-id", "", "移行元の DB インスタンス識別子（必須）")
	parameterGroup := flag.String("target-parameter-group", "", "Green に関連付けた 8.4 パラメータグループ名（必須）")
	outputDir := flag.String("output-dir", "", "収集結果の出力先ディレクトリ（必須）")
	lagWindow := flag.Duration("replica-lag-window", 10*time.Minute, "レプリカ遅延を見る期間")
	flag.Parse()

	for name, value := range map[string]string{
		"region": *region, "source-id": *sourceID,
		"target-parameter-group": *parameterGroup, "output-dir": *outputDir,
	} {
		if value == "" {
			fmt.Fprintf(os.Stderr, "--%s is required.\n", name)
			os.Exit(2)
		}
	}

	result, err := greenstate.Collect(greenstate.Options{
		Region:               *region,
		Profile:              *profile,
		SourceInstanceID:     *sourceID,
		TargetParameterGroup: *parameterGroup,
		OutputDir:            *outputDir,
		ReplicaLagWindow:     *lagWindow,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// eval されるので、値はシェル向けに単一引用符で囲む。
	for _, pair := range [][2]string{
		{"DEPLOYMENT_ID", result.DeploymentID},
		{"GREEN_INSTANCE_ID", result.GreenInstanceID},
		{"GREEN_ENDPOINT", result.GreenEndpoint},
	} {
		fmt.Printf("%s=%s\n", pair[0], shellQuote(pair[1]))
	}
}

// shellQuote は値を単一引用符で囲む。値に含まれる ' は '\” に置き換える。
func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
