// collect_green_runtime_values は Green DB へ接続し、CloudFormation テンプレートが
// 宣言しているパラメータの**実効値**を performance_schema.global_variables から取る。
//
// AWS API は呼ばない。接続情報の解決（SSM Parameter Store からの取得など）は
// 呼び出し元のシェル（scripts/lib/mysql_credentials.sh）が済ませ、パスワードは
// 環境変数で渡される。**パスワードをコマンド引数に取らない。**
//
// MySQL クライアントの代わりにこれを使う理由:
//   - VerifyGreen は RDS のある VPC 内で動かす場合があり、そこから apt リポジトリへ
//     到達できない。つまり実行時に mysql クライアントを導入できない
//   - aws/codebuild/standard:7.0 は mysql クライアントを含まない
//     （libmysqlclient-dev はあるが開発用ライブラリである）
//   - 静的リンクの 1 バイナリなら、レポート生成器と同じ artifact 経路で運べる
//
// TLS は **VERIFY_CA 相当**である。証明書チェーンは検証するが、ホスト名は検証しない。
// MySQL クライアントの --ssl-mode=VERIFY_CA に合わせてある。
package main

import (
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"

	"rds-mysql-upgrade/scripts/internal/cfn"
)

// RDS のトラストストア（公開情報）をバイナリへ焼き込む。実行側は VPC 内から
// 外部へ出られないため、実行時に取得する選択肢が無い。
// 更新するとき:
//
//	curl -o scripts/collect_green_runtime_values/rds-global-bundle.pem \
//	  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
//
//go:embed rds-global-bundle.pem
var embeddedRDSCABundle []byte

// RuntimeValues は収集結果である。レポート生成器の --runtime-values が読む。
type RuntimeValues struct {
	CollectedAt string            `json:"CollectedAt"`
	Parameters  map[string]string `json:"Parameters"`
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func main() {
	templatePath := flag.String("template", "", "Step 2 の CloudFormation テンプレート（収集対象のパラメータ名をここから決める）")
	host := flag.String("host", "", "Green DB のエンドポイント")
	port := flag.Int("port", 3306, "接続ポート")
	user := flag.String("user", "", "接続ユーザー")
	outputPath := flag.String("output", "", "出力する JSON")
	passwordEnv := flag.String("password-env", "MYSQL_PASSWORD", "パスワードを載せた環境変数の名前")
	sslCA := flag.String("ssl-ca", "", "CA バンドルのパス。未指定なら焼き込んだ RDS のバンドルを使う")
	timeout := flag.Duration("timeout", 30*time.Second, "接続とクエリのタイムアウト")
	flag.Parse()

	if *templatePath == "" || *host == "" || *user == "" || *outputPath == "" {
		die("--template, --host, --user, --output は必須である。")
	}

	// 収集対象は CloudFormation テンプレートが宣言しているパラメータだけである。
	// 短縮記法（!Ref / !Sub）の正規化を含む読み取りは internal/cfn が担う。
	names, err := cfn.ParameterNames(*templatePath)
	if err != nil {
		die("%v", err)
	}

	password := os.Getenv(*passwordEnv)
	if password == "" {
		die("環境変数 %s が空である。呼び出し元で解決して渡すこと。", *passwordEnv)
	}

	tlsConfigName, err := registerTLS(*sslCA)
	if err != nil {
		die("%v", err)
	}

	values, err := collect(*host, *port, *user, password, tlsConfigName, names, *timeout)
	if err != nil {
		die("%v", err)
	}

	if err := writeJSON(*outputPath, values); err != nil {
		die("%v", err)
	}
	fmt.Printf("Collected runtime values: %s\n", *outputPath)
}

// registerTLS は VERIFY_CA 相当の TLS 設定を driver へ登録する。
//
// 証明書チェーンは検証するが**ホスト名は検証しない**。これは MySQL クライアントの
// --ssl-mode=VERIFY_CA と同じ挙動である。Go の既定はホスト名も検証する
// （VERIFY_IDENTITY 相当）ため、InsecureSkipVerify で既定の検証を切り、
// VerifyPeerCertificate でチェーンだけを自前で検証する。
// **InsecureSkipVerify だけを立てて終わりにはしない。**
func registerTLS(caPath string) (string, error) {
	pemBytes := embeddedRDSCABundle
	if caPath != "" {
		content, err := os.ReadFile(caPath)
		if err != nil {
			return "", fmt.Errorf("CA バンドルを読めない: %w", err)
		}
		pemBytes = content
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pemBytes) {
		source := "焼き込んだ RDS のバンドル"
		if caPath != "" {
			source = caPath
		}
		return "", fmt.Errorf("CA バンドルから証明書を 1 つも読めない: %s", source)
	}

	config := &tls.Config{
		// 既定の検証（ホスト名を含む）を切り、下でチェーンだけを検証する。
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			certs := make([]*x509.Certificate, 0, len(rawCerts))
			for _, raw := range rawCerts {
				certificate, err := x509.ParseCertificate(raw)
				if err != nil {
					return fmt.Errorf("サーバー証明書を解析できない: %w", err)
				}
				certs = append(certs, certificate)
			}
			if len(certs) == 0 {
				return fmt.Errorf("サーバーが証明書を提示しなかった")
			}
			intermediates := x509.NewCertPool()
			for _, certificate := range certs[1:] {
				intermediates.AddCert(certificate)
			}
			// DNSName を設定しない = ホスト名を検証しない（VERIFY_CA 相当）。
			_, err := certs[0].Verify(x509.VerifyOptions{
				Roots:         pool,
				Intermediates: intermediates,
			})
			if err != nil {
				return fmt.Errorf("サーバー証明書のチェーンを検証できない: %w", err)
			}
			return nil
		},
	}
	const name = "rds-verify-ca"
	if err := mysql.RegisterTLSConfig(name, config); err != nil {
		return "", fmt.Errorf("TLS 設定を登録できない: %w", err)
	}
	return name, nil
}

// collect は 1 本の SELECT で実効値を取る。**値は SQL に含めない。**
// パラメータ名は cfn.ParameterNames が [A-Za-z0-9_]+ に限定済みである。
func collect(host string, port int, user, password, tlsConfigName string, names []string, timeout time.Duration) (*RuntimeValues, error) {
	config := mysql.NewConfig()
	config.User = user
	config.Passwd = password
	config.Net = "tcp"
	config.Addr = net.JoinHostPort(host, strconv.Itoa(port))
	config.DBName = "performance_schema"
	config.TLSConfig = tlsConfigName
	config.Timeout = timeout
	config.ReadTimeout = timeout
	config.WriteTimeout = timeout
	// 値をそのまま受け取る（mysql --raw と同じ扱いにする）。
	config.InterpolateParams = false

	db, err := sql.Open("mysql", config.FormatDSN())
	if err != nil {
		return nil, fmt.Errorf("接続設定が不正である: %w", err)
	}
	defer db.Close()

	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(names)), ",")
	query := "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables " +
		"WHERE VARIABLE_NAME IN (" + placeholders + ") ORDER BY VARIABLE_NAME"
	arguments := make([]any, 0, len(names))
	for _, name := range names {
		arguments = append(arguments, name)
	}

	// [DB 読み取り] Green DB が実際に採用している実効値を取る。変更は行わない。
	rows, err := db.Query(query, arguments...)
	if err != nil {
		return nil, fmt.Errorf("実効値を取得できない: %w", err)
	}
	defer rows.Close()

	parameters := make(map[string]string, len(names))
	for rows.Next() {
		var name string
		var value sql.NullString
		if err := rows.Scan(&name, &value); err != nil {
			return nil, fmt.Errorf("結果を読めない: %w", err)
		}
		parameters[name] = value.String
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("結果を読めない: %w", err)
	}

	return &RuntimeValues{
		CollectedAt: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		Parameters:  parameters,
	}, nil
}

// writeJSON は原子的に書き出す。途中で失敗した出力を後段へ渡さないためである。
func writeJSON(path string, values *RuntimeValues) error {
	content, err := json.MarshalIndent(values, "", "  ")
	if err != nil {
		return fmt.Errorf("JSON へ変換できない: %w", err)
	}
	content = append(content, '\n')

	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return fmt.Errorf("%s: 出力先を作れない: %w", directory, err)
	}
	temporary, err := os.CreateTemp(directory, ".green-runtime-values-*")
	if err != nil {
		return fmt.Errorf("%s: 一時ファイルを作れない: %w", directory, err)
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(content); err != nil {
		temporary.Close()
		return fmt.Errorf("%s: 書き込めない: %w", temporary.Name(), err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("%s: 閉じられない: %w", temporary.Name(), err)
	}
	if err := os.Rename(temporary.Name(), path); err != nil {
		return fmt.Errorf("%s: 置き換えられない: %w", path, err)
	}
	return nil
}
