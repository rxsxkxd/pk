# al2-instance — 今の構成に近いインスタンスを手元で再現する Docker の定義

> 位置付け: [port-guard-rollout](../README.md)（国内だけに絞る設定を複数台に入れる道具）を試す相手として、**今の構成（Amazon Linux 2・Apache 2.4.56・Passenger 6.0.18・Ruby 2.7.7・Rails 4.2）に近いインスタンス**を Docker で再現する。
>
> 確認日: 2026-10-28（手元の arm64 の Mac の Docker Desktop で、ビルド・起動・下の「確かめた構成」まで確認した）
>
> 同じ構成を、開発用のアカウントの本番とは別の VPC に EC2 として作るための定義: [EC2 Image Builder の定義](./image-builder/README.md)（下書き・未検証）

## フォルダの中身

| ファイル | 内容 |
|---|---|
| `Dockerfile` | Amazon Linux 2 の上に、今のインスタンスと同じ版の Apache・Ruby・Passenger をそろえ、最小の Rails 4.2 のアプリを置く |
| `compose.yaml` | 22・80・443 番を手元の 2222・8080・8443 番に出す。`ssh/` の公開鍵を渡す。iptables と ipset をコンテナの中で試せるよう `NET_ADMIN` を付ける。`/health` での稼働確認 |
| `entrypoint.sh` | `ssh/` の公開鍵を `centos` の `authorized_keys` にし、SSH のサーバー・cron・Apache を起動する（コンテナでは systemd を動かさない） |
| `ssh/` | SSH でログインするための、この環境の専用の鍵を置く。中身は Git に入れない（`ssh/.gitignore`） |
| `httpd/passenger.conf.template` | Passenger の読み込み。今のインスタンスの設定と同じ形のパスになる（ビルドのときに版を埋める） |
| `httpd/app.conf` | HTTP（80）と HTTPS（443、`Protocols h2 http/1.1`）の仮想ホスト |
| `app/` | 最小の Rails 4.2 のアプリ。`/health` で、Ruby・Rails・OpenSSL の版と接続元の IP を返す。`Gemfile.lock` はビルドで解決した結果を写したもの |

## 使い方

このフォルダで実行する。

```bash
# 初回だけ: SSH でログインするための専用の鍵を作る（ssh/ の中身は Git に入れない）
ssh-keygen -t ed25519 -N '' -C al2-instance-local -f ssh/id_ed25519

docker compose build          # 初回は 10 分前後（Ruby・Passenger の Apache のモジュール・nokogiri のコンパイル）
docker compose up -d
curl -s http://localhost:8080/health
curl -sk https://localhost:8443/health

# 今のインスタンスと同じく、centos で SSH で入る（sudo はパスワードなし）
ssh -i ssh/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null centos@localhost

docker compose exec al2-instance bash                 # （補助）root で入る

docker compose down
```

`/health` の応答の例:

```
ruby: 2.7.7
rails: 4.2.11.3
openssl: OpenSSL 1.0.2k-fips  26 Jan 2017
remote_addr: 192.168.65.1
```

## 構成

### 今のインスタンスと合わせたもの

| 要素 | この定義 | 入れ方 |
|---|---|---|
| OS | Amazon Linux 2（glibc 2.26） | 公開のコンテナイメージ。2026-10-28 に取得したものに digest で固定 |
| Apache | **2.4.56**（`Server built: Mar 16 2023`）、`mod_ssl` 2.4.56 | yum で版を指定 |
| HTTP/2 | `mod_http2` 1.15.19 | yum で版を指定（下の「Apache と HTTP/2 の版」） |
| MPM | **prefork**（AL2 の既定のまま） | 変えていない |
| Ruby | **2.7.7**（rbenv、`/home/centos/.rbenv`） | rbenv と ruby-build でソースからビルド |
| Passenger | **6.0.18**（Ruby の gem。`mod_passenger.so` は gem の中の `buildout/apache2/`） | `gem install` と `passenger-install-apache2-module` |
| Passenger の設定 | `LoadModule passenger_module /home/centos/.rbenv/versions/2.7.7/lib/ruby/gems/2.7.0/gems/passenger-6.0.18/buildout/apache2/mod_passenger.so` など、今のインスタンスと同じパス | テンプレートに版を埋める |
| ユーザー | `centos`（`sudo` をパスワードなしで使える。ホームディレクトリは 711） | `useradd` |
| ログインのしかた | **SSH で直接**（`centos`、鍵での認証。パスワードでのログインと root でのログインは不可） | `openssh-server` |
| 最初から入っているもの | `iptables`（コマンドだけ）、`cronie`、`sudo`、`openssh-server` | 今のインスタンスに近づけた |
| 入れていないもの | **`amazon-ssm-agent`**、`ipset`、`iptables-services`、`firewalld`、`openssl11` | 今のインスタンスは SSH で直接入っていて、SSM Agent は入っていない見込み。port-guard-rollout が入れる前の状態にした |

### 今のインスタンスと違うもの

| 違い | 理由と影響 |
|---|---|
| **systemd を動かさない** | Docker Desktop の仕組みと AL2 の古い systemd（219）の組み合わせが合わないため。cron と Apache は `entrypoint.sh` で起動する。**systemd のユニット（`port-guard.service` など）の起動・起動時の有効化・再起動の後の復元は、この環境では試せない**（`systemctl is-enabled` でユニットの設定を見ることはできる） |
| SSM は試せない | SSM Agent は入れていない（今のインスタンスに合わせた）。入れても、systemd がなく AWS に登録もしないので、Session Manager や Run Command は試せない。「SSM の準備」のうち、SSH での確認と `yum install amazon-ssm-agent` までは試せる |
| Rails の取り方と範囲 | 今のアプリは git の 4-2-stable だが、ここでは RubyGems の 4.2.11.3 を使い、Passenger で動かすのに要る部分（`railties` と `actionpack`）だけを入れる |
| `bigdecimal` 1.4.4 | Ruby 2.7 に同梱の bigdecimal 2.0 には `BigDecimal.new` がなく、Rails 4.2 が起動しないため固定した（今のアプリも同じ対応をしているはず） |
| RubyGems 3.4.22・Bundler 2.4.22 | Ruby 2.7 で使える最後の版。Ruby 2.7.7 に付いてくる古い Bundler では、Ruby 2.7 に対応しない gem を選んでしまうおそれがあるため |
| アーキテクチャ | 手元の Mac に合わせて arm64。今のインスタンス（t3a）は x86_64 |
| nokogiri をソースからビルド（arm64 のときだけ） | arm64 向けのビルド済みの nokogiri は glibc 2.29 以上を求め、AL2（glibc 2.26）では読み込めないため。x86_64 向けのビルド済みのものは AL2 で動くので、x86_64 ではそのまま使う |
| ネットワーク | コンテナのネットワークの中。接続元の IP は Docker のもの（例: `192.168.65.1`）になり、国の判定は試せない（許可する IP の集合で代わりに試す） |
| 証明書 | 自己署名の証明書（`/etc/pki/tls/certs/localhost.crt`） |

### Apache と HTTP/2 の版

AL2 では、`mod_http2` が Apache とは別の版の番号で出ている。版を指定しないと最新の `mod_http2`（2.4.69）が選ばれ、それが Apache 2.4.69 を求めるので、Apache 2.4.56 と一緒に入らない。2.4.56 と組み合わせられる版（1.15.19、2.0.42）がリポジトリに残っているので、1.15.19 を指定した。**今のインスタンスの版は `rpm -q mod_http2` で確かめる**（違えば `MOD_HTTP2_VERSION` を合わせる）。

参考に、AL2 のリポジトリの Apache 2.4.69 の `mod_ssl` と `mod_http2` は OpenSSL 1.1（`openssl11`）を使っている。今のインスタンスが Apache を更新すると、使う OpenSSL も変わる。

## 確かめた構成（2026-10-28）

今のインスタンスについての推定（[今の構成を AL2023 で作り直す検討の補足](../../initial-image-build/existing-system-rebuild-on-al2023.md#補足-今の-al2-の構成の状態推定)）を、この再現の環境で確かめた。

| 項目 | 結果 |
|---|---|
| Apache | `Apache/2.4.56 ()`、`Server built: Mar 16 2023 14:38:12` |
| MPM | **prefork**。エラーのログに `AH10034: The mpm module (prefork.c) is not supported by mod_http2 ... the HTTP/2 protocol will be inactive` が出て、**HTTP/2 は効いていない**（`curl --http2` でも HTTP/1.1 になる） |
| `mod_ssl` が使う OpenSSL | **1.0.2k**（`libssl.so.10`、`libcrypto.so.10`） |
| `mod_http2` が使う OpenSSL | 1.0.2k（`libcrypto.so.10`） |
| Passenger（`PassengerAgent`）が使う OpenSSL | 1.0.2k（`libssl.so.10`、`libcrypto.so.10`。libcurl を通して NSS の `libssl3.so` も読み込む） |
| Ruby の `openssl` | ビルド時・実行時とも **1.0.2k**。ruby-build は OpenSSL を同梱していない（OS の 1.0.2k を使っている） |
| 動いている Apache が読み込んでいるもの | `/usr/lib64/libssl.so.1.0.2k`、`/usr/lib64/libcrypto.so.1.0.2k`（`/proc/<プロセス番号>/maps` では、`libssl.so.10` ではなく実体のファイル名で見える） |
| TLS 1.3 | **使えない**（`httpd -t -c 'SSLProtocol TLSv1.2 TLSv1.3'` が `Illegal protocol 'TLSv1.3'`） |
| iptables | `iptables v1.8.4 (legacy)`。ルールはなく、すべて受け付ける（`-P INPUT ACCEPT` など 3 行） |
| ipset・iptables-services・firewalld | 入っていない |
| SSM Agent | 入れていない（最初の確認のときは入れていたが、今のインスタンスに合わせて外した） |
| SSH | `centos` で鍵を使ってログインでき、`sudo` をパスワードなしで使える。パスワードでのログインと root でのログインは拒否される（`Permission denied (publickey,...)`）。`openssh-server` 7.4p1 |
| Ruby（ログインのシェル） | `ruby 2.7.7p221 (2022-11-24 revision 168ec2b1e5) [aarch64-linux]`（rbenv の shims。今のインスタンスと、アーキテクチャ以外は同じ表示） |
| プロセス | Apache（root と `apache`）、Passenger の watchdog と core（root）、アプリ（`centos` の `Passenger AppPreloader` と `Passenger RubyApp`） |
| イメージの大きさ | 1.48 GB（ビルドの道具を含む） |

**推定どおりだったもの**: Apache・Ruby・Passenger がすべて OS の OpenSSL 1.0.2k の上に乗っていること、TLS 1.3 を使えないこと。

**新しく分かったこと**: AL2 の既定の MPM は prefork で、このままだと HTTP/2 は効かない。今のインスタンスで MPM を変えていなければ、「HTTP/2 を使っている」つもりでも、実際は HTTP/1.1 で動いている可能性が高い（今のインスタンスの `httpd -V` とエラーのログで確かめる）。

なお、コンテナの中では、root でも別のユーザーのプロセス（`centos` のアプリ）の `/proc/<プロセス番号>/maps` は読めなかった（コンテナに `SYS_PTRACE` の権限がないため）。EC2 の上では、`sudo` で読める。

## この環境で試せること・試せないこと

| 試せる | 試せない |
|---|---|
| ipset の導入、集合の作成と中身の入れ替え、iptables のルールの追加と削除（`NET_ADMIN` があるので、コンテナのネットワークの中だけに効く） | systemd のユニットの起動・有効化・再起動の後の復元 |
| 許可する IP の集合で、手元（Mac）からの接続を許可・遮断できるか | 国の判定（接続元が Docker の IP になるため） |
| 「事前の確認」のスクリプトの、パッケージ・ルール・集合の確認の部分 | SSM の Run Command・Session Manager、AWS の API を使う処理（AMI の作成など） |
| SSH でのログインと、SSH を通した処理（[ssm-setup](../../ssm-setup/README.md) の `ssm-agent` の確認と、SSM Agent のインストール） | SSM Agent の登録（`Online`）と、その後の動作の確認 |
| cron での定期の更新 | x86_64 での動作（手元は arm64） |

ipset と iptables の照合は、コンテナではなく Docker Desktop の仮想マシンのカーネルが行う。ipset のカーネルのモジュールが使えるかは、port-guard の処理を試すときに確かめる。

## 参考

- [今の構成を AL2023 で作り直す検討](../../initial-image-build/existing-system-rebuild-on-al2023.md)（今の構成と、OpenSSL の使われ方の推定）
- [暫定対応: OS（iptables ＋ ipset、または firewalld）](../../notes/ec2-operations/access-restriction-os-firewall.md)（このインスタンスに入れる設定とスクリプト）
- [設計: 国内だけに絞る設定を複数台に入れるスクリプト](../../notes/ec2-operations/access-restriction-rollout-script-design.md)
