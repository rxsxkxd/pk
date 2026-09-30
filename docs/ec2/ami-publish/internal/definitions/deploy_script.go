package definitions

import (
	"fmt"
	"strings"
)

// DeployScriptPath は、環境ごとのデプロイ用シェルスクリプトの出力先（generated/ からの相対パス）。
func DeployScriptPath(environmentName string) string {
	return "deploy/" + environmentName + ".sh"
}

// DeployScript は、仕組み（3 つのスタック）をデプロイ・削除する AWS CLI の呼び出しを並べたシェルスクリプトを返す。
//
//	bash generated/deploy/<環境>.sh up    … 依存関係の順に変更セットを作る（反映はしない。確認と反映は担当者が行う）
//	bash generated/deploy/<環境>.sh down  … 依存関係の逆順にスタックを削除する
//
// スタック名は命名規則から決まるため、担当者が --stack-name を手で書くと、AMI 公開ツールが探す名前とずれることがある。
// このスクリプトを使えば、正しいスタック名とテンプレートのパスで操作できる。
// チェックなどの処理は入れず、AWS CLI の呼び出しを並べるだけにする。
func DeployScript(environment Environment) string {
	// upNote は up のときだけ出す補足
	type stack struct{ title, upNote, name, template string }
	// 依存関係の順（up はこの順、down は逆順）
	stacks := []stack{
		{"ヘルスチェック（SSM ドキュメント）", "", environment.HealthCheckStackName(), "health-check-stack.yml"},
		{"起動テンプレート", "（AmiId / AppVersion は指定しない。初回は空で作られ、以降は現在の値を引き継ぐ）",
			environment.LaunchTemplateStackName(), "launch-template-stack.yml"},
		{"AMI 公開パイプライン", "", environment.PipelineStackName(), "ami-publish-pipeline-stack.yml"},
	}
	region := environment.AWSRegion
	scriptPath := "generated/" + DeployScriptPath(environment.Name)

	var script strings.Builder
	script.WriteString("#!/bin/bash\n")
	script.WriteString("# このファイルは cmd/generate-definitions が config/ami_publish.yml から生成した。手で編集しない。\n")
	fmt.Fprintf(&script, "# 環境 %s の仕組み（3 つのスタック）をデプロイ・削除する。ami-publish/ のルートで実行する。\n", environment.Name)
	script.WriteString("#\n")
	fmt.Fprintf(&script, "#   bash %s up    依存関係の順に変更セットを作る（反映はしない）\n", scriptPath)
	fmt.Fprintf(&script, "#   bash %s down  依存関係の逆順にスタックを削除する\n", scriptPath)
	script.WriteString("#\n")
	script.WriteString("# up の後は、表示される変更セットを確認してから、依存関係の順に反映する:\n")
	script.WriteString("#   aws cloudformation describe-change-set --stack-name <スタック名> --change-set-name <変更セット名>\n")
	script.WriteString("#   aws cloudformation execute-change-set  --stack-name <スタック名> --change-set-name <変更セット名>\n")
	script.WriteString("# down はスタックのリソースを削除する。AMI とスナップショットはスタックのリソースではないため残る。\n")
	script.WriteString("set -eu\n")

	script.WriteString("\nup() {\n")
	for index, s := range stacks {
		fmt.Fprintf(&script, "  # %d. %s%s\n", index+1, s.title, s.upNote)
		fmt.Fprintf(&script, "  aws cloudformation deploy --region %s --stack-name %s \\\n", region, s.name)
		fmt.Fprintf(&script, "    --template-file generated/cloudformation/%s/%s \\\n", environment.Name, s.template)
		script.WriteString("    --capabilities CAPABILITY_IAM --no-execute-changeset --no-fail-on-empty-changeset\n")
	}
	script.WriteString("}\n")

	script.WriteString("\ndown() {\n")
	for index := len(stacks) - 1; index >= 0; index-- {
		s := stacks[index]
		fmt.Fprintf(&script, "  # %d. %s\n", len(stacks)-index, s.title)
		if s.name == environment.PipelineStackName() {
			script.WriteString("  # アーティファクト用の S3 バケットは、中身が残っているとスタックを削除できないため先に空にする\n")
			fmt.Fprintf(&script, "  bucket=$(aws cloudformation describe-stacks --region %s --stack-name %s \\\n", region, s.name)
			script.WriteString("    --query \"Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue\" --output text)\n")
			fmt.Fprintf(&script, "  aws s3 rm --region %s \"s3://${bucket}\" --recursive\n", region)
		}
		fmt.Fprintf(&script, "  aws cloudformation delete-stack --region %s --stack-name %s\n", region, s.name)
		fmt.Fprintf(&script, "  aws cloudformation wait stack-delete-complete --region %s --stack-name %s\n", region, s.name)
	}
	script.WriteString("}\n")

	script.WriteString("\ncase \"${1:-}\" in\n")
	script.WriteString("  up) up ;;\n")
	script.WriteString("  down) down ;;\n")
	fmt.Fprintf(&script, "  *) echo \"使い方: bash %s up|down\" >&2; exit 2 ;;\n", scriptPath)
	script.WriteString("esac\n")
	return script.String()
}
