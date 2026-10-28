# 検討: 今の構成（AL2・Apache・Passenger・Rails 4.2・Ruby 2.7.7）を AL2023 で作り直せるか

> 位置付け: 検討の整理。採用済みの設計ではない。Amazon Linux 2（AL2）で動いている今の構成を、**なるべくそのまま** Amazon Linux 2023（AL2023）で作り直せるかを、資料とパッケージの一覧から机上で検討したもの。あわせて、特定のポートへのアクセスを国内と特定の IP に絞る制限の入れ方を検討する。**どれも動かして確かめてはいない**。
>
> 関連: [土台の構成](./base-image-composition.md)（AL2023 での層の分け方と Ruby の入れ方）、[現状の手作業によるインスタンスの構築手順の整理](../instance-provisioning/manual-procedure-analysis.md)、[Docker の定義（ruby-build）](./docker/al2023-ruby3.4/README.md)、[前段の構成（CloudFront と ALB）](../notes/instance-provisioning/cloudfront-alb-front-options.md)
>
> 調査日: 2026-10-28（パッケージの有無とバージョンは、AL2023 の 2023.12.20261021 のリリースのパッケージの一覧で確認した）

## 結論

| # | 結論 |
|---|---|
| 1 | **作り直しはできる見込み**。Apache・HTTP/2・Passenger・Ruby 2.7.7・Rails 4.2 の組み合わせは、AL2023 でも保てる |
| 2 | Ruby 2.7.7 は、**ruby-build でソースからビルドするしかない**（AL2023 のパッケージは Ruby 3.2・3.4・4.0、mise のビルド済みの Ruby に 2.7 はない）。AL2023 には OpenSSL 1.1 のパッケージがないため、**ruby-build が OpenSSL 1.1.1w を一緒にビルドして Ruby に同梱する** |
| 3 | Apache（2.4.69）、`mod_ssl`、`mod_http2` は AL2023 のパッケージで入る。Passenger は今と同じく gem で入れ、`mod_passenger` を AL2023 の Apache に合わせてビルドする |
| 4 | **一番の不確定要素は、アプリの gem（ネイティブ拡張）**。`Gemfile.lock` を見るまで、AL2023 でビルドできるかを判断できない |
| 5 | OS は AL2023 になり更新を受けられるが、**Ruby 2.7（2023-03 にサポート終了）、OpenSSL 1.1.1（2023-09 にサポート終了）、Rails 4.2（4-2-stable の最後の変更は 2020-07）には修正が出ない**。作り直しは土台を新しくするだけで、アプリの側の脆弱性は残る。アプリの側を Rails 5.x まで上げても、これらの懸念はほとんど残る（[補足](#補足-アプリの側を-rails-5x-まで上げたとき懸念がどこまで消えるか)） |
| 6 | アクセス制限は、**OS の nftables に「日本の IP の範囲」と「許可する IP」の集合を入れ、特定のポートはその集合からだけ受け付ける**形を勧める。HTTP(S) のパス単位で絞りたいときは Apache、業務の条件で絞りたいときはアプリ。前段に ALB や CloudFront を置くと、OS と Apache から利用者の IP が見えなくなる点に注意する |

## なぜ作り直すか

AL2 は **2026-06-30 にサポートが終了している**（[Amazon Linux 2](https://aws.amazon.com/amazon-linux-2/)、[Amazon Linux 2 FAQs](https://aws.amazon.com/amazon-linux-2/faqs/)）。今のインスタンスは動き続けるが、OS のセキュリティ更新はもう出ない。AL2 から AL2023 へのその場でのアップグレードの手段はないため、AL2023 で作り直す。

## 今の構成と AL2023 での対応

| 要素 | 今（AL2） | AL2023 での入れ方 | 変わる点・確かめること |
|---|---|---|---|
| OS | Amazon Linux 2 | AL2023 | 既定のユーザーは `ec2-user`（`centos` はない）。cron は入っていない（`cronie` で入れる）。SELinux は有効で permissive |
| Apache | 2.4.56（AL2 のパッケージ） | `httpd` 2.4.69（AL2023 のパッケージ） | マイナーバージョンが上がる。設定ファイルの置き場所（`/etc/httpd/conf.d/`、`conf.modules.d/`）は同じ流儀 |
| HTTP/2 | `mod_http2` | `mod_http2` 2.0.42（AL2023 のパッケージ。`httpd` とは別に入れる） | **HTTP/2 は MPM が prefork だと使えない**（event か worker が要る）。今の MPM を `httpd -V` で確かめる |
| TLS | `mod_ssl` | `mod_ssl`（AL2023 のパッケージ） | Apache が受ける TLS は、**AL2023 の OpenSSL 3 で処理され、OS の更新で直る** |
| Passenger | 6.0.18（rbenv の Ruby の gem。`mod_passenger.so` を gem の中でビルド） | 同じく gem で入れ、`passenger-install-apache2-module` で AL2023 の Apache に合わせてビルドする | ビルドに `gcc-c++`、`httpd-devel`、`apr-devel`、`apr-util-devel`、`libcurl-devel`、`openssl-devel`、`zlib-devel` が要る（どれも AL2023 にある）。6.0.18 のままでよいか、6.0 系の最後の 6.0.27（2025-04）にするかは下の M3 |
| Ruby | 2.7.7（rbenv、`/home/centos/.rbenv`） | **ruby-build でソースからビルド**（OpenSSL 1.1.1w を同梱） | 下の「Ruby 2.7.7 のビルド」 |
| Rails | 4-2-stable（git で取得） | 同じ（`Gemfile.lock` のとおり） | `bundle install` で GitHub から取得する。4-2-stable は 2020-07 から変わっていないので、取れる内容は今と同じ |
| Bundler | `Gemfile.lock` の `BUNDLED WITH` による | 同じバージョンを入れる | Ruby 2.7.7 の同梱は 2.1.4。Rails 4.2.11.3 の railties は Bundler のバージョンを縛っていない |
| ユーザーとパス | `centos`、`/home/centos/.rbenv/...` | 下の M2 | Apache の設定（`LoadModule`、`PassengerRoot`、`PassengerDefaultRuby`）がこのパスを直接書いている |
| Let's Encrypt | certbot | `certbot` 2.6.0（AL2023 のパッケージ。EPEL は要らない） | 証明書の扱いは [Let's Encrypt の扱い](../notes/instance-provisioning/letsencrypt-certificate-timing.md) |
| 定期実行 | cron（と思われる） | `cronie` を入れるか、systemd のタイマー | 今の crontab を棚卸しする |

## Ruby 2.7.7 のビルド

### 入れ方の選択肢

| 入れ方 | 2.7.7 を入れられるか |
|---|---|
| AL2023 のパッケージ | **できない**（`ruby3.2`・`ruby3.4`・`ruby4.0` だけ） |
| mise のビルド済みの Ruby（jdx/ruby） | **できない**（2.7 のビルド済みの Ruby はない。mise を使うとソースからのビルドになる） |
| ruby-build（rbenv を含む） | **できる**。今と同じ入れ方 |

[土台の構成](./base-image-composition.md) の Ruby の入れ方は、B（ruby-build）しか選べないことになる。

### OpenSSL 1.1.1w の同梱

ruby-build の Ruby 2.7.7 の定義は、OS の OpenSSL が 1.0.1〜1.x でなければ、**OpenSSL 1.1.1w のソースを取得してビルドし、Ruby の置き場所の中に入れる**（`install_package "openssl-1.1.1w" ... --if needs_openssl:1.0.1-1.x.x`）。AL2023 の OpenSSL は 3 系なので、こちらになる。Ruby 2.7 に同梱の `openssl` の拡張ライブラリ（2.1 系）は、OpenSSL 3 に対応していないため。

| 影響 | 内容 |
|---|---|
| ビルドに要るもの | `gcc`、`make`、`perl`（OpenSSL のビルドに使う）、`zlib-devel`、`libyaml-devel`、`libffi-devel`、`readline-devel`、`tar`、**`bzip2`**（2.7.7 のソースは `.tar.bz2`） |
| セキュリティ | OpenSSL 1.1.1 は 2023-09 にサポートが終わっていて、修正は出ない。ただし**外から受ける TLS は Apache（OS の OpenSSL 3）が処理する**ので、1.1.1w を使うのは Ruby の中の処理（外部の API への HTTPS、メールの送信の TLS、Cookie などの暗号化）に限られる |
| 証明書 | 同梱の OpenSSL が、OS の証明書（`/etc/pki/tls/certs/ca-bundle.crt` など）を読めるか。Ruby から外部に HTTPS でつなぐときの検証で問題になる（**要確認**） |
| 2 つの OpenSSL | Ruby の `openssl` は 1.1.1w、`mysql2` が使う MariaDB の接続ライブラリや libcurl は OS の OpenSSL 3 を使う。同じプロセスに 2 つの OpenSSL が読み込まれる。ライブラリの名前（`libssl.so.1.1` と `libssl.so.3`）が違うので、多くの場合は問題ないが、**要確認** |

OpenSSL 1.1.1 を避ける案として、「Ruby 2.7 に、OpenSSL 3 に対応した `openssl` gem（3.x 系。Ruby 2.6 以上に対応）を組み合わせる」方法もある。ただし、Ruby のビルドの手順から変える必要があり、確かめる量が増える。まずは ruby-build の既定（1.1.1w の同梱）で動くかを確かめ、この案は保留にする。

### 2.7.7 か 2.7.8 か

2.7 系の最後は 2.7.8（2023-03-31）で、2.7.7 からの差はセキュリティの修正（URI と Time の正規表現の処理の DoS）である。ruby-build にはどちらの定義もある。「なるべくそのまま」なら 2.7.7、同じ 2.7 系で直せるものは直すなら 2.7.8（下の M1）。

## Passenger と Apache の構成

Passenger 以外のアプリケーションサーバー（Puma・Unicorn・Pitchfork）や Passenger Standalone との比較は [アプリケーションサーバーの選択肢](./existing-system-app-server-options.md)。

| 項目 | 内容 |
|---|---|
| Passenger のバージョン | 6.0.18（2023-06）のままを第一にする。AL2023 の gcc 11・OpenSSL 3・Apache 2.4.69 でビルドできないときは、6.0 系の最後の 6.0.27 を試す。最新は 6.2.1（2026-10。Ruby 2.5.9 以上に対応）だが、変わる量が大きい |
| ビルドのしかた | Ruby の持ち主のユーザーで `gem install passenger -v 6.0.18` → `passenger-install-apache2-module`。できた `mod_passenger.so` の場所は今と同じ形（gem の中の `buildout/apache2/`） |
| MPM | HTTP/2 を使うなら event（または worker）。Passenger は event で動く。今が prefork なら、HTTP/2 は今も効いていない可能性がある |
| HTTP/2 の設定 | `mod_http2` を入れ、TLS の仮想ホストに `Protocols h2 http/1.1` |
| ホームディレクトリの権限 | Apache（`apache` ユーザー）が `/home/<ユーザー>/.rbenv` の下の `mod_passenger.so` と Ruby を読めるよう、ホームディレクトリに実行の権限が要る（今の AL2 と同じ対応） |
| SELinux | AL2023 は permissive なので、ホームディレクトリの下のモジュールを読んでも止められない（記録はされる）。将来 enforcing にするなら、置き場所を `/opt` などに移すか、SELinux の設定が要る |

## アプリの gem の確認事項

`Gemfile.lock` を見るまで判断できない。Rails 4.2 の時代のアプリでよく使われる gem について、AL2023 での見込みをまとめる。

| gem | AL2023 での見込み | 必要なパッケージ |
|---|---|---|
| `mysql2` | ビルドできる見込み | `mariadb-connector-c-devel`、または `mariadb1011-devel`（`mariadb105-devel` はサポート終了） |
| `pg` | ビルドできる見込み | `libpq-devel` |
| `nokogiri` | 今がビルド済みの gem（`x86_64-linux`）ならそのまま。ソースからビルドしているなら | `libxml2-devel`、`libxslt-devel` |
| `therubyracer`（`libv8`） | **ビルドできない可能性が高い**（古い V8 のビルド） | 代わりに Node.js を ExecJS の実行環境にする（`nodejs22`・`nodejs24` がある）。Gemfile の変更になる |
| `rmagick`・`mini_magick` | ImageMagick 6 で動く版なら見込みあり | `ImageMagick-devel`（6.9.13） |
| `openssl` を使う C 拡張（`eventmachine`、`puma` など） | OS の `openssl-devel`（3 系）でビルドされ、Ruby の 1.1.1w とずれる | **要確認** |
| 古い C 拡張全般 | AL2023 の gcc は 11 系で、新しい gcc（14 以降）ほど古いコードに厳しくない。ビルドできる見込みは比較的高い | `gcc`、`gcc-c++`、`make` |
| `bigdecimal` まわり | 今 Ruby 2.7.7 で動いているので、対応済みのはず | — |

## 特定のポートのアクセス制限

### 要件の読み方

「特定のポートに、国内以外・特定の IP 以外からアクセスがあったらブロックする」を、**特定のポートは「日本の IP」か「許可した IP」からだけ受け付け、それ以外は破棄する**と読む。

| 形 | 内容 | 勧めるか |
|---|---|---|
| 許可の一覧（静的） | 最初から、一覧にない接続元を破棄する | **勧める**。単純で、取りこぼしがない |
| 検知して遮断（動的） | 一覧にない接続元からのアクセスを検知してから、遮断の一覧に足す（fail2ban など。AL2023 に `fail2ban` 1.1.0 がある） | 今回の要件には合わない（最初の接続は通ってしまう）。ログインの失敗の繰り返しなどへの対策向け |

### どの層で絞るか

| 層 | 国で絞れるか | IP で絞れるか | 対象 | 利点 | 注意 |
|---|---|---|---|---|---|
| （参考）セキュリティグループ | できない | できる | すべてのポート | インスタンスに届く前に止まる。費用なし | 日本の IP の範囲は数千件あり、ルールの数の上限に収まらない。**IP の許可だけなら、ここが一番簡単** |
| **OS（nftables / firewalld / iptables＋ipset）** | できる（IP の範囲の一覧を入れる） | できる | すべてのポート・プロトコル | Apache やアプリに届く前に止まる。数千件の範囲でも軽い | 一覧の更新の仕組みが要る。SSH のポートを絞るなら、締め出しへの備えが要る |
| Apache | できる（`mod_maxminddb`。AL2023 にパッケージがなく、ソースからビルド） | できる（`Require ip`） | HTTP(S) のポートだけ | **パス単位**（例: `/admin` だけ）で絞れる。拒否がアクセスのログに残る | 接続そのものは Apache まで届く |
| アプリ（Rails） | できる（MaxMind の gem など） | できる | アプリの処理だけ | 利用者や機能ごとなど、業務の条件で絞れる | Passenger とアプリまで処理が進んでから断る。止まっている Rails 4.2 のアプリへのコードの変更になる |
| WAF | — | — | — | — | 今回は除外 |

**勧める形**: IP の許可だけで足りるポートはセキュリティグループで絞る。国で絞るポートは OS の nftables で絞る。HTTP(S) のポートで、特定のパスだけを絞りたいときは Apache を足す。アプリでの実装は、業務の条件が要るときだけにする。

### OS での入れ方の比較（AL2023）

| 手段 | AL2023 のパッケージ | 内容 | 勧めるか |
|---|---|---|---|
| **nftables** | `nftables` 1.0.4 | AL2023 のファイアウォールの本体（iptables のコマンドも、裏では nftables を使う）。範囲の集合（`set ... flags interval`）を持てる。`nftables.service` で起動時に設定を読み込む | **勧める**。常駐するものが増えず、設定が 1 つのファイルにまとまる |
| firewalld | `firewalld` 1.2.3 | nftables の上の管理の仕組み。ipset（`hash:net`）と rich rule で同じことができる | `firewall-cmd` に慣れた人が運用するなら選択肢。常駐するデーモンが増える |
| iptables ＋ ipset | `iptables-services`、`iptables-nft`、`ipset` 7.11 | 昔ながらの形。AL2023 では iptables のコマンドが nftables に変換される | 今の手順や知識を流用したいとき。新しく作るなら nftables の方が素直 |

今の AL2 のインスタンスでは、firewalld も iptables・ipset のサービスも入っていない。どれを選んでも、入れるところからになる。

### nftables の設定の例（考え方を示すもの）

対象のポート（例: 8443）だけを守り、ほかの通信には影響させない（ほかのポートの絞り込みは、セキュリティグループに任せる）。

```
table inet port_guard {
    # 許可する IP（サーバーごとの値。別のファイルから読み込む）
    set allow_v4 {
        type ipv4_addr
        flags interval
        elements = { 203.0.113.10, 198.51.100.0/24 }
    }

    # 日本の IP の範囲（定期的に更新するファイルから読み込む）
    set jp_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    chain input {
        type filter hook input priority 0; policy accept;

        tcp dport 8443 ip saddr @allow_v4 accept
        tcp dport 8443 ip saddr @jp_v4 accept
        tcp dport 8443 meta nfproto ipv6 drop   # IPv6 を使わないなら、まとめて破棄する
        tcp dport 8443 counter log prefix "port_guard drop: " drop
    }
}
```

### 日本の IP の範囲の取り方

| 取得元 | 内容 | 注意 |
|---|---|---|
| APNIC の割り当ての統計（`delegated-apnic-latest`） | 無料。毎日更新。IP アドレスが**どの国の組織に割り当てられたか** | 実際に使われている場所（位置）とは限らない。範囲は「先頭と個数」の形なので、CIDR に変換する |
| MaxMind GeoLite2 Country | 無料（アカウントとライセンスキーが要る）。週 2 回更新。**位置の推定**として精度が高い | 利用条件（表示、更新の義務など）を確認する。`geoipupdate` は AL2023 にないので、取得は自分で書く |
| ipdeny などの加工済みの一覧 | 国ごとの CIDR の一覧をそのまま取れる | 第三者の加工物で、正しさと継続性に依存する |

### 一覧の更新の仕組み

| 項目 | 内容 |
|---|---|
| 頻度 | 週 1 回〜毎日。systemd のタイマー（cron は既定で入っていない） |
| 手順 | 取得 → 件数などの妥当性の確認 → 集合の中身の入れ替えを 1 つの nftables のトランザクション（`nft -f`）で行う |
| 失敗したとき | **古い一覧のまま残す**。取得に失敗して空の一覧で入れ替えると、全員を締め出す（または、作りによっては全員を通す） |
| 記録 | 入れ替えた件数と日時をログに残す。破棄した接続は `counter` と `log` で数える |

### 注意

| 点 | 内容 |
|---|---|
| 位置の判定は完全ではない | 海外にいる日本の利用者、VPN、海外のクラウドや監視サービス、決済などの外部サービスからの通知（webhook）は「日本以外」になりうる。必要な相手は許可する IP に足す |
| 締め出し | SSH のポートを絞るなら、Systems Manager の Session Manager で入れるようにしておく（[SSM Session Manager による EC2 運用](../notes/ec2-operations/ssm-session-manager-operations.md)） |
| 前段に ALB や CloudFront を置く場合 | インスタンスに届く接続元は ALB や CloudFront になり、**OS と Apache の IP での判定が効かなくなる**。そのときは CloudFront の地域制限（追加費用なし）や、Apache・アプリで `X-Forwarded-For` を使う判定に移す（[前段の構成](../notes/instance-provisioning/cloudfront-alb-front-options.md)） |
| AMI での配り方 | nftables の設定と一覧の更新の仕組みは土台（層 1）に入れる。**許可する IP はサーバーごとの値**なので、AMI には焼き込まず、起動時に入れる（[今の手作業の手順の整理](../instance-provisioning/manual-procedure-analysis.md) のサーバーごとの値と同じ扱い） |

### Apache で絞る場合の例（参考）

`mod_maxminddb` はソースからビルドする（`libmaxminddb-devel` と `httpd-devel` は AL2023 にある）。

```apache
MaxMindDBEnable On
MaxMindDBFile COUNTRY_DB /usr/share/GeoIP/GeoLite2-Country.mmdb
MaxMindDBEnv MM_COUNTRY_CODE COUNTRY_DB/country/iso_code
SetEnvIf MM_COUNTRY_CODE ^JP$ FROM_JAPAN

<Location /admin>
    <RequireAny>
        Require ip 203.0.113.10
        Require env FROM_JAPAN
    </RequireAny>
</Location>
```

## 層の分け方への当てはめ

| 層 | 入るもの |
|---|---|
| 層 1: 下回り（土台） | Ruby 2.7.x（ruby-build、OpenSSL 1.1.1w を同梱）、Passenger の gem と `mod_passenger`、`httpd`・`mod_ssl`・`mod_http2`、gem のビルドに要るもの（`gcc`、`*-devel`）、Node.js（要るなら）、`cronie`、nftables の設定と日本の IP の範囲の更新の仕組み、アプリのユーザー |
| 層 2: 上物 | アプリ（Rails 4.2 と gem。`Gemfile.lock` のとおり） |
| サーバーごとの値（起動時） | `ServerName`、許可する IP、証明書、メールのホスト名など |

## 確かめる手順（案）

| # | 内容 | 使う手順・定義 |
|---|---|---|
| 1 | 今のサーバーから材料を集める: `Gemfile`・`Gemfile.lock`、`httpd -V`（MPM）、Apache の設定一式、crontab、gem のネイティブ拡張が使っている OS のライブラリ（`.so` の `ldd`）、OpenSSL の使われ方（[補足の推定を確かめる方法](#推定を確かめる方法)） | [AMI から開発用のインスタンスを起動し、ファイルを S3 に集める](../instance-provisioning/development-collect-files-from-ami.md) |
| 2 | Docker で AL2023 の上に、ruby-build で Ruby 2.7.7、Passenger と `mod_passenger`、アプリの `bundle install` まで通るかを試す（取得するデータが多いので、実行前に確認する） | [Docker の定義（ruby-build）](./docker/al2023-ruby3.4/README.md) を元に作る |
| 3 | Docker の上で Apache と Passenger でアプリを起動し、HTTP/2 と TLS を確かめる | 同上 |
| 4 | nftables の設定と一覧の更新を、開発用のインスタンスで試す（締め出しに備えて Session Manager で入る） | — |
| 5 | EC2 Image Builder の定義に移す | [EC2 Image Builder の定義（ruby-build）](./image-builder/al2023-ruby3.4/README.md) を元に作る |

## 決めること

| # | 論点 | 選択肢 |
|---|---|---|
| M1 | Ruby を 2.7.7 のままにするか、2.7.8 にするか | 2.7.7（そのまま） / 2.7.8（2.7 系の最後のセキュリティの修正を含む） |
| M2 | `centos` ユーザーとパスを保つか | `centos` ユーザーを作ってパスを保つ（Apache の設定や `.bashrc` をそのまま使える） / `ec2-user` や専用のユーザーに移す / Ruby を `/opt` に移す（SELinux の enforcing を見据えるなら） |
| M3 | Passenger のバージョン | 6.0.18（そのまま） / 6.0.27（6.0 系の最後） / 6.2 系。アプリケーションサーバーの選択肢との比較は [アプリケーションサーバーの選択肢](./existing-system-app-server-options.md) |
| M4 | OpenSSL 1.1.1 を受け入れるか | ruby-build の既定（1.1.1w の同梱）で進める / OpenSSL 3 に対応した `openssl` gem を組み合わせる案を検討する（扱いにくいので保留）。Ruby 2.7 系のままでは同梱は残る（[補足](#補足-アプリの側を-rails-5x-まで上げたとき懸念がどこまで消えるか)） |
| M5 | 制限するポートとプロトコル、IPv6 の扱い | ポートごとに、セキュリティグループ・OS・Apache のどこで絞るか |
| M6 | 日本の IP の範囲の取得元 | APNIC / MaxMind GeoLite2 / 加工済みの一覧 |
| M7 | 許可する IP の管理 | サーバーごとの値として起動時に入れる / Parameter Store などで共通に管理する |
| M8 | アプリの側を上げるか | 上げない（Rails 4.2 のまま） / Rails 5.x まで上げる（5.1 で止めるなら 5.2 の方がよい）。懸念がどこまで消えるかは [補足](#補足-アプリの側を-rails-5x-まで上げたとき懸念がどこまで消えるか) |

## 補足: 今の AL2 の構成の状態（推定）

今のサーバーでは確かめていない。資料と、ruby-build の動き方からの推定である。下の「推定を確かめる方法」で確定させる。

### OpenSSL の使われ方

AL2 の標準の OpenSSL は **1.0.2k**（`openssl-1.0.2k-fips`）である。1.1.1 は `openssl11` という別のパッケージで、入れても標準の OpenSSL は置き換わらない。

| 部分 | 使っている OpenSSL（推定） | 根拠 |
|---|---|---|
| OS の標準 | 1.0.2k | AL2 の標準のパッケージ |
| Apache（`mod_ssl`） | **1.0.2k** | AL2 の `httpd` と `mod_ssl` は標準の OpenSSL を使うように作られている。`openssl11` を入れても Apache は 1.0.2k のまま、という報告がある（[re:Post](https://repost.aws/de/questions/QU2-NW2PYSQq6oXRP-xb0xdg/amazon-linux-2-apache-and-open-ssl-1-1-x)、[`openssl11` のパッケージの修正のお知らせ](https://alas.aws.amazon.com/AL2/ALAS-2024-2564.html)） |
| Ruby 2.7.7（rbenv） | **1.0.2k の可能性が高い** | ruby-build は、OS の OpenSSL が 1.0.1〜1.x なら OS のものを使う（`pkg-config` で `openssl` のバージョンを見る）。`openssl-devel`（1.0.2k）が入っていれば、それでビルドされる |
| Passenger（`mod_passenger` と、その裏で動くプロセス） | 1.0.2k | ビルドに使った `openssl-devel` と `libcurl` が標準のもの |

Apache だけが OpenSSL に引きずられているのではなく、**全部が OS の標準の 1.0.2k の上に乗っている**形と考えられる。その結果:

- **今の Apache は TLS 1.3 を使えない**（OpenSSL 1.0.2 が TLS 1.3 に対応していない）
- **1.0.2k にはもう修正が出ない**。開発元のサポートは 2019 年に終わり、その後は AWS が修正を入れてきたが、それも AL2 のサポートの終了（2026-06-30）で止まった

### AL2023 での変わり方

| 部分 | 今（AL2） | AL2023 |
|---|---|---|
| Apache | 1.0.2k。TLS 1.3 なし | OpenSSL 3。TLS 1.3 あり。OS の更新で直る |
| Ruby 2.7.7 | 1.0.2k（推定） | ruby-build が同梱する 1.1.1w。TLS 1.3 を使えるようになるが、どちらもサポートは終わっている |
| Passenger | 1.0.2k | OpenSSL 3 |

上の「Ruby 2.7.7 のビルド」で、Ruby だけが OpenSSL 1.1.1w を使うと書いたが、今の状態（1.0.2k）と比べて悪くなるわけではない。

新しく気を付けることとして、AL2023 は、システム全体の暗号の方針で、古い TLS（1.0・1.1）や弱い鍵を既定で拒否するはずである（**要確認**）。古い端末から Apache につながらなくなる、Ruby の外にあるデータベースのクライアントなどが古い相手につながらなくなる、といった影響がありうる。

### ほかに問題がありそうな箇所

| # | 箇所 | 問題 | 重さ |
|---|---|---|---|
| 1 | OS 全体（AL2） | 2026-06-30 にサポートが終わり、カーネル・Apache・OpenSSL を含めて修正が出ない | 高 |
| 2 | Rails 4.2（4-2-stable） | 最後の変更は 2020-07。それ以降に見つかった Rails の脆弱性の修正は入っていない | 高 |
| 3 | Ruby 2.7.7 | 2023-03 にサポート終了。同じ 2.7 系の最後の 2.7.8 にあるセキュリティの修正（URI と Time の DoS）も入っていない | 中〜高 |
| 4 | OpenSSL 1.0.2k | 上のとおり。TLS 1.3 なし | 中 |
| 5 | HTTP/2 | **MPM が prefork だと、`mod_http2` を読み込んでいても HTTP/2 は効かない**（Apache のエラーログに、効かないという警告が出る）。今も効いているとは限らない | 確認が要る |
| 6 | Passenger 6.0.18 | 2023-06 の版。6.0 系は 6.0.27（2025-04）まで出ている | 中 |
| 7 | Passenger と Ruby の置き場所 | Apache が `centos` ユーザーのホームディレクトリの下のモジュールを直接読んでいる。Ruby を入れ替えると `mod_passenger` も作り直しが要る | 低（作りの問題） |
| 8 | `centos` ユーザー | AL2 の標準は `ec2-user`。手作業で作ったか、CentOS から移した名残と思われる。手順書とパスがこれに依存している | 低 |
| 9 | OS のファイアウォールがない | firewalld も iptables も入っておらず、絞り込みはセキュリティグループだけ。今回の制限を入れるなら新しく入れる | 今回の要件しだい |

### 推定を確かめる方法

推定のうち、次の 4 つを今のサーバーで確かめる。どのコマンドも読み取りだけで、設定やサービスは変えない（`httpd -t` は設定の文法の確認だけで、動いている Apache には影響しない）。

| # | 確かめること | 推定どおりなら | 推定と違ったら |
|---|---|---|---|
| V1 | AL2 の標準の OpenSSL は 1.0.2k か | `OpenSSL 1.0.2k-fips` | `openssl11` が標準を置き換えていることはないはずなので、パッケージの状態を見直す |
| V2 | Apache・Ruby・Passenger が 1.0.2k を使っているか | どれも `libssl.so.10` / `libcrypto.so.10`（1.0.2k のライブラリの名前） | `libssl.so.1.1`（1.1.1。`openssl11` か ruby-build の同梱）なら、その部分は 1.1.1 を使っている |
| V3 | 今の Apache は TLS 1.3 を使えないか | 外からの TLS 1.3 の接続が失敗し、`SSLProtocol` に `TLSv1.3` を書くと文法の誤りになる | TLS 1.3 でつながるなら、Apache は 1.1.1 以上の OpenSSL を使っている |
| V4 | OpenSSL にもう修正が出ないか | パッケージの最後の変更が 2026-06-30 より前で、それ以降に更新がない | — |

**ライブラリの名前の見分け方**: AL2 の 1.0.2k は `libssl.so.10` と `libcrypto.so.10`、`openssl11` の 1.1.1 は `libssl.so.1.1` と `libcrypto.so.1.1`。ruby-build が OpenSSL を同梱した場合は、Ruby の置き場所の中の `openssl/lib/libssl.so.1.1` を指す。

前提: 今のサーバーに SSH か Session Manager で入り、Ruby の持ち主（`centos`）で実行する。`sudo` が要るものはそう書いた。パスは貼られた設定（`/home/centos/.rbenv/versions/2.7.7`、`passenger-6.0.18`）に合わせている。

#### V1: 標準の OpenSSL

```bash
openssl version
# 推定どおりなら: OpenSSL 1.0.2k-fips  26 Jan 2017

rpm -q openssl openssl-libs openssl-devel openssl11 openssl11-libs openssl11-devel
# openssl / openssl-libs / openssl-devel が 1.0.2k、openssl11 系は「インストールされていない」か 1.1.1g
```

#### V2: Apache・Ruby・Passenger が使っている OpenSSL

ファイルが何に依存しているか（`ldd`）と、**動いているプロセスが実際に読み込んでいるもの**（`/proc/<プロセス番号>/maps`）の 2 つで見る。

```bash
# Apache の mod_ssl
ldd /usr/lib64/httpd/modules/mod_ssl.so | grep -E 'libssl|libcrypto'

# 動いている Apache が読み込んでいる OpenSSL（mod_ssl と mod_passenger を含む）
sudo grep -hE 'libssl|libcrypto' /proc/$(pgrep -o httpd)/maps | awk '{print $6}' | sort -u
```

```bash
RUBY_ROOT=/home/centos/.rbenv/versions/2.7.7

# Ruby の openssl の拡張ライブラリが、どのバージョンでビルドされ（OPENSSL_VERSION）、何を読み込んでいるか（OPENSSL_LIBRARY_VERSION）
"$RUBY_ROOT/bin/ruby" -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION, OpenSSL::OPENSSL_LIBRARY_VERSION'
# 推定どおりなら: どちらも OpenSSL 1.0.2k-fips  26 Jan 2017

# 拡張ライブラリの依存先
ldd "$("$RUBY_ROOT/bin/ruby" -ropenssl -e 'puts $LOADED_FEATURES.grep(/openssl\.so/).first')" | grep -E 'libssl|libcrypto'

# ruby-build が OpenSSL を同梱したか（同梱したなら、openssl のディレクトリがある）
ls -d "$RUBY_ROOT/openssl" 2>/dev/null || echo "OpenSSL は同梱していない（OS のものを使っている）"
"$RUBY_ROOT/bin/ruby" -e 'puts RbConfig::CONFIG["configure_args"]' | tr ' ' '\n' | grep -i openssl

# 動いているアプリのプロセス（Passenger が起動した Ruby）が読み込んでいる OpenSSL
sudo grep -hE 'libssl|libcrypto' /proc/$(pgrep -of 'Passenger RubyApp')/maps | awk '{print $6}' | sort -u
```

```bash
PASSENGER_ROOT=$RUBY_ROOT/lib/ruby/gems/2.7.0/gems/passenger-6.0.18

# Apache のモジュールと、裏で動くプロセス（PassengerAgent）の依存先
ldd "$PASSENGER_ROOT/buildout/apache2/mod_passenger.so" | grep -E 'libssl|libcrypto|libcurl'
ldd "$PASSENGER_ROOT/buildout/support-binaries/PassengerAgent" | grep -E 'libssl|libcrypto|libcurl'
```

`ldd` で何も表示されないときは、OpenSSL を直接は使っていない（間接に使っているものは、`/proc/<プロセス番号>/maps` の方で見える）。

#### V3: 今の Apache は TLS 1.3 を使えないか

サーバーの中で、設定の文法の確認だけを行う（`-c` で、設定を読み込んだ後に 1 行足して確かめる。設定ファイルは変えない）。

```bash
sudo httpd -t -c 'SSLProtocol TLSv1.2 TLSv1.3'
# 推定どおりなら: SSLProtocol: Illegal protocol 'TLSv1.3' のような誤り
# TLS 1.3 に対応していれば: Syntax OK
```

外から（手元の PC から）、実際につないで確かめる。

```bash
# TLS 1.3 だけでつなぐ（推定どおりなら失敗する）
curl -sv --tlsv1.3 --tls-max 1.3 -o /dev/null https://<ホスト名>/ 2>&1 | grep -E 'SSL connection|alert|error'

# 手元の openssl が TLS 1.3 に対応していれば、こちらでもよい
openssl s_client -connect <ホスト名>:443 -servername <ホスト名> -tls1_3 </dev/null 2>&1 | grep -E 'Protocol|alert|error'

# 比べるために TLS 1.2 でつなぐ（成功するはず）
curl -sv --tlsv1.2 --tls-max 1.2 -o /dev/null https://<ホスト名>/ 2>&1 | grep -E 'SSL connection'
```

あわせて、HTTP/2 が効いているかも見る（MPM が prefork なら `1.1` になる）。

```bash
curl -s --http2 -o /dev/null -w '%{http_version}\n' https://<ホスト名>/   # 2 なら HTTP/2 が効いている
sudo httpd -V | grep -i mpm
sudo grep -i http2 /var/log/httpd/error_log | tail -5                    # prefork で効かないときの警告
```

#### V4: OpenSSL にもう修正が出ないか

```bash
# 入っているパッケージの作成日と、最後の変更の記録
rpm -qi openssl | grep -E 'Version|Release|Build Date'
rpm -q --changelog openssl | head -5

# リポジトリに新しい版がないか（読み取りだけ）
sudo yum check-update openssl openssl-libs httpd mod_ssl
```

最後の変更が 2026-06-30（AL2 のサポートの終了）より前で、その後に新しい版が出ていなければ、推定どおり修正はもう出ない。AL2 で出た修正は [Amazon Linux Security Center](https://alas.aws.amazon.com/alas2.html) でも確かめられる。

#### 結果の記録

確かめた結果は、この補足の表（「使っている OpenSSL（推定）」）を実際の値に書き換え、確かめた日を書き足す。

## 補足: アプリの側を Rails 5.x まで上げたとき、懸念がどこまで消えるか

論点 M4（OpenSSL 1.1.1）と M8（アプリの側を上げるか）の判断の材料。Ruby は 2.7 系のままとする。サポートの期間は [endoflife.date](https://endoflife.date/rails) の値、stable ブランチの最後の変更は GitHub の rails/rails で確認した（2026-10-28）。

### Rails 5.1 まで上げた場合: 懸念はほとんど消えない

| 懸念 | Rails 4.2 のまま | Rails 5.1 に上げた場合 | 緩和 |
|---|---|---|---|
| OS（AL2 のサポートの終了） | AL2023 への作り直しで解消 | 同じ（Rails とは関係ない） | — |
| Rails の脆弱性 | 4.2 のサポートの終了は 2017-04。最後のセキュリティのリリースは 4.2.11.3（2020-05）、4-2-stable の最後の変更は 2020-07 | **5.1 のサポートの終了は 2019-08**。最後のリリースは 5.1.7（2019-03）、5-1-stable の最後の変更は 2019-07 | **ほぼなし**。修正が止まった時期は、4.2 より 5.1 の方がむしろ早い |
| Ruby 2.7 | 2.7 | **2.7 のまま** | なし |
| Ruby に同梱する OpenSSL 1.1.1 | Ruby 2.7 なので要る | Ruby 2.7 のままなので要る | なし |
| アプリの gem を AL2023 でビルドできるか | 古い gem に縛られる | 少し新しい gem を使えるようになる。ただ Ruby 2.7 の制約は残る | 少しある |
| Rails を git のブランチから取る | GitHub への依存がある | RubyGems のリリースを使える | 少しある（運用の面だけ） |
| Apache・Passenger・HTTP/2 | — | 変わらない | — |

### 判断の材料

| 点 | 内容 |
|---|---|
| 5.1 で止めるなら 5.2 | 4.2 から 5.0 に上げる段階に作業の大半があり（モデルの関連付けの必須化、新しい設定の既定値など）、5.1 から 5.2 はそれに比べて小さい。5.2 は修正が 2022-06 まで出ていた（最後は 5.2.8.1、2022-07）ので、5.1 よりは新しい状態で止まれる |
| Rails 5.x に上げても残るもの | Ruby 2.7（サポート終了）と、Ruby に同梱する OpenSSL 1.1.1（サポート終了）。どちらも Rails 5.x の範囲では消えない |
| Ruby の側でできること | 2.7.7 から、2.7 系の最後の 2.7.8 に上げる（論点 M1。URI と Time の DoS の修正を含む） |
| OpenSSL 1.1.1 を避ける抜け道 | OpenSSL 3 に対応した `openssl` gem（3.0 以上。Ruby 2.6 以上に対応）を足して、OS の OpenSSL 3 を使わせる方法は、理屈の上ではある（論点 M4 の 2 つ目の選択肢）。ただし、Ruby 本体のビルドの時点では 1.1.1w が要ること、RubyGems が `https` から gem を取るにも `openssl` を使うので入れる順番に工夫が要ること、アプリが `openssl` を読み込む前に新しい gem を有効にする必要があることから、扱いにくい。**保留** |
| 外から受ける TLS | Apache が AL2023 の OpenSSL 3 で処理するので、Rails や Ruby の版に関係なく、OS の更新で直る |

## 参考

- [Amazon Linux 2](https://aws.amazon.com/amazon-linux-2/)、[Amazon Linux 2 FAQs](https://aws.amazon.com/amazon-linux-2/faqs/)（AL2 のサポートの終了: 2026-06-30）
- [Amazon Linux 2023 RPM packages as of the 2023.12.20261021 release](https://docs.aws.amazon.com/linux/al2023/release-notes/all-packages-AL2023.12.html)（パッケージの有無とバージョン）
- [ruby-build の Ruby 2.7.7 の定義](https://github.com/rbenv/ruby-build/blob/master/share/ruby-build/2.7.7)（OpenSSL 1.1.1w の同梱の条件）
- [passenger - RubyGems](https://rubygems.org/gems/passenger)（6.0.18: 2023-06、6.0.27: 2025-04、6.2.1: 2026-10）
- [rails/rails の 4-2-stable](https://github.com/rails/rails/tree/4-2-stable)（最後の変更: 2020-07-09）、[5-1-stable](https://github.com/rails/rails/tree/5-1-stable)（最後の変更: 2019-07-10）
- [Ruby on Rails - endoflife.date](https://endoflife.date/rails)（Rails のサポートの期間）
- [HTTP/2 guide - Apache HTTP Server](https://httpd.apache.org/docs/2.4/howto/http2.html)（prefork の MPM では HTTP/2 を使えない）
- [Amazon Linux 2 apache and open ssl 1.1.x - re:Post](https://repost.aws/de/questions/QU2-NW2PYSQq6oXRP-xb0xdg/amazon-linux-2-apache-and-open-ssl-1-1-x)、[ALAS2-2024-2564（`openssl11`）](https://alas.aws.amazon.com/AL2/ALAS-2024-2564.html)（AL2 の Apache は OpenSSL 1.0.2k を使い、TLS 1.3 を使えない）
