// Package report は、生成した Blue/Green 実行設定を人がレビューするための
// Markdown レポートを組み立てる。
//
// AWS を一切呼ばない。入力は generate と同じ（移行カタログと RDS インベントリ）で、
// 判定の重複を避けるため deployment の組み立ては internal/generate を再利用する。
//
// **このレポートは可否を判定しない。** アプリケーションと接続先の対応、目標
// インスタンスクラス、パラメータグループの内容は人がレビューする対象であり、
// レポートはその材料を一か所に並べるだけである。
package report

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"rds-mysql-upgrade/scripts/internal/cfn"
	"rds-mysql-upgrade/scripts/internal/common"
	"rds-mysql-upgrade/scripts/internal/generate"
)

// Report は 1 環境分のレビュー資料である。
type Report struct {
	Environment string
	AwsRegion   string
	// Deployments は RDS インスタンス識別子の昇順である。
	Deployments []*Deployment
}

// Deployment は 1 つの Blue/Green 実行単位と、そこへ繋がる接続である。
type Deployment struct {
	Service     *generate.Service
	Connections []generate.ConnectionRef
	// TargetParameterGroup は Step 2 のテンプレートが宣言している 8.4 側の値である。
	// 読めなかった場合は nil で、理由が TargetParameterGroupError に入る。
	TargetParameterGroup      *cfn.ParameterGroup
	TargetParameterGroupError string
}

// 比較の判定。レポートの表と要確認事項で同じ語を使う。
const (
	VerdictSame        = "一致"
	VerdictDifferent   = "差異"
	VerdictIntrinsic   = "比較不能"
	VerdictNotDeclared = "テンプレート未宣言"
	VerdictNoTemplate  = "テンプレート未確認"
)

// ParameterComparison は、Blue の実値と 8.4 テンプレートの適用予定値の突き合わせである。
type ParameterComparison struct {
	Name          string
	Current       string
	CurrentSource string
	// Planned は表示用の文字列である（組み込み関数や未確認の場合は理由が入る）。
	Planned string
	Verdict string
}

// Comparisons は採取したパラメータごとに、現状と適用予定値を突き合わせる。
// パラメータ名の昇順で返す。
func (deployment *Deployment) Comparisons() []ParameterComparison {
	var comparisons []ParameterComparison
	for _, name := range common.SortedKeys(deployment.Service.SourceDBParameters) {
		current := deployment.Service.SourceDBParameters[name]
		comparison := ParameterComparison{
			Name:          name,
			Current:       current.Value,
			CurrentSource: current.Source,
		}
		switch {
		case deployment.TargetParameterGroup == nil:
			comparison.Planned = "—"
			comparison.Verdict = VerdictNoTemplate
		default:
			planned, resolved, intrinsic := deployment.TargetParameterGroup.Parameter(name)
			switch {
			case resolved && planned == current.Value:
				comparison.Planned = planned
				comparison.Verdict = VerdictSame
			case resolved:
				comparison.Planned = planned
				comparison.Verdict = VerdictDifferent
			case intrinsic != "":
				comparison.Planned = intrinsic
				comparison.Verdict = VerdictIntrinsic
			default:
				comparison.Planned = "—"
				comparison.Verdict = VerdictNotDeclared
			}
		}
		comparisons = append(comparisons, comparison)
	}
	return comparisons
}

// Build はカタログとインベントリからレポートを組み立てる。
func Build(catalog *generate.Catalog, inventory *common.Inventory, environmentName string) (*Report, error) {
	document, err := generate.Generate(catalog, inventory, environmentName)
	if err != nil {
		return nil, err
	}

	byInstance := map[string][]generate.ConnectionRef{}
	for _, ref := range generate.ConnectionsIn(catalog, environmentName) {
		byInstance[ref.RDSInstance] = append(byInstance[ref.RDSInstance], ref)
	}

	report := &Report{Environment: document.Environment, AwsRegion: document.AwsRegion}
	// 同じテンプレートを複数インスタンスが指しうるため、読み込みは 1 回で済ませる。
	templates := map[string]*cfn.ParameterGroup{}
	failures := map[string]string{}
	for _, instance := range common.SortedKeys(document.Services) {
		service := document.Services[instance]
		path := service.TargetParameterGroupTemplatePath
		if _, done := templates[path]; !done {
			if _, failed := failures[path]; !failed {
				group, err := cfn.ReadDBParameterGroup(path)
				if err != nil {
					// テンプレートは Step 2 の成果物である。まだ無い段階でも
					// レポートは出す。読めなかった事実をそのまま載せる。
					failures[path] = err.Error()
				} else {
					templates[path] = group
				}
			}
		}
		report.Deployments = append(report.Deployments, &Deployment{
			Service:                   service,
			Connections:               byInstance[instance],
			TargetParameterGroup:      templates[path],
			TargetParameterGroupError: failures[path],
		})
	}
	return report, nil
}

// Write はレポートを Markdown として原子的に書く。
func Write(path string, report *Report) error {
	return common.WriteAtomic(path, func(file *os.File) error {
		_, err := file.WriteString(report.Markdown())
		return err
	})
}

// Markdown はレポート本文を返す。
func (report *Report) Markdown() string {
	var out strings.Builder
	report.writeSummary(&out)
	report.writeDeployments(&out)
	report.writeConnections(&out)
	report.writeParameters(&out)
	report.writeVerification(&out)
	report.writeReviewPoints(&out)
	return out.String()
}

func (report *Report) writeSummary(out *strings.Builder) {
	connections := 0
	applications := map[string]bool{}
	for _, deployment := range report.Deployments {
		connections += len(deployment.Connections)
		for _, ref := range deployment.Connections {
			applications[ref.Application] = true
		}
	}

	fmt.Fprintf(out, "# Blue/Green 移行設定レビュー: %s\n\n", report.Environment)
	out.WriteString("移行カタログと RDS インベントリから生成した、切替前レビュー用の資料である。" +
		"**可否は判定しない。** 判断材料を一か所に並べるだけである。\n\n")
	out.WriteString("| 項目 | 値 |\n|---|---|\n")
	fmt.Fprintf(out, "| 環境 | %s |\n", report.Environment)
	fmt.Fprintf(out, "| リージョン | %s |\n", report.AwsRegion)
	fmt.Fprintf(out, "| Blue/Green 実行単位（RDS インスタンス） | %d |\n", len(report.Deployments))
	fmt.Fprintf(out, "| 接続定義 | %d |\n", connections)
	fmt.Fprintf(out, "| アプリケーション | %d |\n", len(applications))
	out.WriteString("\n")
}

func (report *Report) writeDeployments(out *strings.Builder) {
	out.WriteString("## 移行元と移行先\n\n")
	out.WriteString("エンジンバージョンは major.minor へ正規化して記録している" +
		"（自動マイナーバージョンアップグレードの差分を判定へ持ち込まないため）。\n\n")
	out.WriteString("| RDS インスタンス | 移行元 | 移行先 | インスタンスクラス | 移行先パラメータグループ |\n")
	out.WriteString("|---|---|---|---|---|\n")
	for _, deployment := range report.Deployments {
		service := deployment.Service
		fmt.Fprintf(out, "| `%s` | %s / `%s` | %s | %s | `%s` |\n",
			service.SourceDBInstanceIdentifier,
			service.SourceEngineVersion, service.SourceDBParameterGroupName,
			service.TargetEngineVersion, service.TargetDBInstanceClass,
			service.TargetDBParameterGroupName)
	}
	out.WriteString("\n")
	out.WriteString("移行先パラメータグループの元テンプレート（Step 2 の成果物）:\n\n")
	for _, deployment := range report.Deployments {
		fmt.Fprintf(out, "- `%s` ← `%s`\n",
			deployment.Service.TargetDBParameterGroupName,
			deployment.Service.TargetParameterGroupTemplatePath)
	}
	out.WriteString("\n")
}

// writeConnections は「この切替で影響を受けるのは誰か」を示す。
// 生成結果（deployment.yml）にはアプリ名が残らないため、ここで補う。
func (report *Report) writeConnections(out *strings.Builder) {
	out.WriteString("## 影響範囲（スキーマと接続元）\n\n")
	out.WriteString("| RDS インスタンス | スキーマ | 接続元（アプリ.接続名） |\n|---|---|---|\n")
	for _, deployment := range report.Deployments {
		service := deployment.Service
		var origins []string
		for _, ref := range deployment.Connections {
			origins = append(origins, fmt.Sprintf("`%s.%s`", ref.Application, ref.Connection))
		}
		if len(origins) == 0 {
			origins = []string{"（カタログに接続が無い）"}
		}
		var schemas []string
		for _, schema := range service.Schemas {
			schemas = append(schemas, "`"+schema+"`")
		}
		fmt.Fprintf(out, "| `%s` | %s | %s |\n",
			service.SourceDBInstanceIdentifier,
			strings.Join(schemas, ", "), strings.Join(origins, ", "))
	}
	out.WriteString("\n")
}

// writeParameters は、現在のパラメータグループの実値と、Step 2 のテンプレートが
// 適用しようとしている値を直接突き合わせて並べる。
func (report *Report) writeParameters(out *strings.Builder) {
	out.WriteString("## パラメータの現状と適用予定値\n\n")
	out.WriteString("「現在」は Blue のパラメータグループから採取した実値（`engine-default` は" +
		"パラメータグループでは未設定＝エンジン既定値）。「適用予定」は移行先パラメータグループの " +
		"CloudFormation テンプレート（Step 2 の成果物）が宣言している値である。\n\n")
	out.WriteString("| RDS インスタンス | パラメータ | 現在 | 由来 | 適用予定 | 判定 |\n")
	out.WriteString("|---|---|---|---|---|---|\n")
	for _, deployment := range report.Deployments {
		for _, comparison := range deployment.Comparisons() {
			current := comparison.Current
			if current == "" {
				current = "（未取得）"
			}
			source := comparison.CurrentSource
			if source == "" {
				source = "（未取得）"
			}
			verdict := comparison.Verdict
			if verdict == VerdictDifferent {
				verdict = "**" + verdict + "**"
			}
			fmt.Fprintf(out, "| `%s` | `%s` | %s | %s | %s | %s |\n",
				deployment.Service.SourceDBInstanceIdentifier, comparison.Name,
				current, source, comparison.Planned, verdict)
		}
	}
	out.WriteString("\n")
	out.WriteString("突き合わせたテンプレート:\n\n")
	for _, deployment := range report.Deployments {
		if deployment.TargetParameterGroupError != "" {
			fmt.Fprintf(out, "- `%s` ← **読み込めなかった**: %s\n",
				deployment.Service.TargetDBParameterGroupName, deployment.TargetParameterGroupError)
			continue
		}
		fmt.Fprintf(out, "- `%s` ← `%s`\n",
			deployment.Service.TargetDBParameterGroupName,
			deployment.Service.TargetParameterGroupTemplatePath)
	}
	out.WriteString("\n")
}

func (report *Report) writeVerification(out *strings.Builder) {
	out.WriteString("## Step 4 の MySQL 接続検証\n\n")
	out.WriteString("`enabled: false` のときは Green DB へ接続せず、AWS API による検証だけを行う。" +
		"**認証情報そのものはカタログにも生成結果にも無く、記録されるのは SSM パラメータ名だけである。**\n\n")
	out.WriteString("| RDS インスタンス | 有効 | パスワード | ユーザー名 | ポート | TLS |\n|---|---|---|---|---|---|\n")
	for _, deployment := range report.Deployments {
		verification := deployment.Service.MySQLVerification
		enabled := "無効"
		password, user := "—", "—"
		if verification.Enabled {
			enabled = "有効"
			password = "`" + verification.ParameterName + "`"
			user = "`" + verification.UserParameterName + "`"
		}
		tls := "指定なし"
		if verification.SSLCA != "" {
			tls = "VERIFY_CA"
		}
		fmt.Fprintf(out, "| `%s` | %s | %s | %s | %d | %s |\n",
			deployment.Service.SourceDBInstanceIdentifier,
			enabled, password, user, verification.Port, tls)
	}
	out.WriteString("\n")
}

// writeReviewPoints は、自動判定しない代わりに人へ渡す確認事項を並べる。
func (report *Report) writeReviewPoints(out *strings.Builder) {
	out.WriteString("## 要確認事項\n\n")

	var points []string

	// 同居しているインスタンスは、切替の影響が複数アプリへ及ぶ。
	for _, deployment := range report.Deployments {
		applications := map[string]bool{}
		for _, ref := range deployment.Connections {
			applications[ref.Application] = true
		}
		if len(applications) > 1 {
			points = append(points, fmt.Sprintf(
				"`%s` は %d アプリが同居している（%s）。切替の停止影響が全アプリへ及ぶ。関係者への周知範囲を確認する。",
				deployment.Service.SourceDBInstanceIdentifier, len(applications),
				strings.Join(sortedNames(applications), ", ")))
		}
		if len(deployment.Service.Schemas) > 1 {
			points = append(points, fmt.Sprintf(
				"`%s` は %d スキーマを収容している。Blue/Green はインスタンス単位で切り替わるため、一部スキーマだけの切替はできない。",
				deployment.Service.SourceDBInstanceIdentifier, len(deployment.Service.Schemas)))
		}
	}

	// 現状と適用予定値の突き合わせ結果のうち、人の確認が必要なものを挙げる。
	for _, deployment := range report.Deployments {
		identifier := deployment.Service.SourceDBInstanceIdentifier
		if deployment.TargetParameterGroupError != "" {
			points = append(points, fmt.Sprintf(
				"`%s` の移行先テンプレート `%s` を読み込めなかった（%s）。"+
					"Step 2 を実施済みか、パスが正しいかを確認する。",
				identifier, deployment.Service.TargetParameterGroupTemplatePath,
				deployment.TargetParameterGroupError))
		}
		for _, comparison := range deployment.Comparisons() {
			switch comparison.Verdict {
			case VerdictDifferent:
				points = append(points, fmt.Sprintf(
					"`%s` の `%s` が切替で `%s` から `%s` へ変わる。意図した変更かを確認する%s。",
					identifier, comparison.Name, comparison.Current, comparison.Planned,
					timeZoneNote(comparison.Name)))
			case VerdictIntrinsic:
				points = append(points, fmt.Sprintf(
					"`%s` の `%s` は移行先テンプレートで組み込み関数（%s）になっており、実値が決まらない。"+
						"スタックのパラメータ値で確認する。",
					identifier, comparison.Name, comparison.Planned))
			case VerdictNotDeclared:
				points = append(points, fmt.Sprintf(
					"`%s` の `%s` は移行先テンプレートで宣言されていない。"+
						"現在の値 `%s`（由来: %s）を引き継がず 8.4 のエンジン既定値になる。意図した変更かを確認する%s。",
					identifier, comparison.Name, comparison.Current, comparison.CurrentSource,
					timeZoneNote(comparison.Name)))
			}
			if comparison.Current == "" || comparison.CurrentSource == "" {
				points = append(points, fmt.Sprintf(
					"`%s` の `%s` を採取できていない。インベントリを再収集する。",
					identifier, comparison.Name))
			}
		}
	}

	// 複数インスタンスが同じ移行先パラメータグループを共有している場合、
	// 片方の変更が他方へ及ぶ。
	sharedGroups := map[string][]string{}
	for _, deployment := range report.Deployments {
		group := deployment.Service.TargetDBParameterGroupName
		sharedGroups[group] = append(sharedGroups[group], deployment.Service.SourceDBInstanceIdentifier)
	}
	for _, group := range common.SortedKeys(sharedGroups) {
		if len(sharedGroups[group]) > 1 {
			points = append(points, fmt.Sprintf(
				"移行先パラメータグループ `%s` を %d インスタンスが共有している（%s）。片方のための変更が他方へも及ぶ。",
				group, len(sharedGroups[group]), strings.Join(sharedGroups[group], ", ")))
		}
	}

	// 接続検証が無効なら、Step 4 は MySQL の実効値を見ない。
	for _, deployment := range report.Deployments {
		if !deployment.Service.MySQLVerification.Enabled {
			points = append(points, fmt.Sprintf(
				"`%s` は mysql_verification が無効である。Step 4 は AWS API による構成確認だけを行い、MySQL の実効値は見ない。",
				deployment.Service.SourceDBInstanceIdentifier))
		}
	}

	// 生成時点では必ず pending である。承認は人が設定ファイルへ書く。
	points = append(points,
		"`actions` は生成時点ですべて `pending` である。実行を許可する操作だけを `approved` へ書き換える"+
			"（CI は設定ファイルへ書き戻さない）。")
	points = append(points,
		"アプリケーションと接続先の対応、目標インスタンスクラス、パラメータグループの内容は自動判定していない。人がレビューする。")

	for _, point := range points {
		fmt.Fprintf(out, "- [ ] %s\n", point)
	}
}

// timeZoneNote は time_zone だけに付く参照先である。datetime 列への影響が論点になる。
func timeZoneNote(parameterName string) string {
	if parameterName != "time_zone" {
		return ""
	}
	return "（DEFAULT CURRENT_TIMESTAMP の datetime 列への影響: " +
		"reference/mysql-timezone-problem-summary.md）"
}

func sortedNames(values map[string]bool) []string {
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
