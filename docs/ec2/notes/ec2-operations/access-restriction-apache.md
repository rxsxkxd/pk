# 暫定対応: Apache 2.4.56 で国内と特定の IP に絞る

> 位置付け: 今の環境（Amazon Linux 2・Apache 2.4.56・Passenger・Rails 4.2・Ruby 2.7.7）に入れる**暫定対応**の検討。AL2023 での作り直し（[今の構成を AL2023 で作り直す検討](../../initial-image-build/existing-system-rebuild-on-al2023.md)）とは別に考える。**動かして確かめてはいない**。
>
> 同じ要件のほかの層: [OS（iptables ＋ ipset、または firewalld）で絞る](./access-restriction-os-firewall.md)、[アプリ（Rails）で絞る](./access-restriction-rails-app.md)
>
> 作成日: 2026-10-28

## 要件

対象（HTTP(S) のポート全体、または特定のパス）について、**国内（日本）からのアクセスは全体を許可し、海外からのアクセスはすべて絞る**。数件の IP を許可するだけでは足りないので、国で判定することが本命になる。日本以外から通す必要がある少数の相手（海外の拠点、外部サービス、外形監視など）は、**許可する IP** として補助的に足す。絞ったリクエストには 403 を返す。

## 結論

| # | 結論 |
|---|---|
| 1 | 要件は国内全体を許可して海外を絞ることなので、**`mod_maxminddb` と MaxMind GeoLite2 のデータベースで国を判定する形が本命**。モジュールのビルドと、データベースの取得と更新の仕組みが要る |
| 2 | **許可する IP（`Require ip`）は補助**として併用する（日本以外から通す必要がある少数の相手のため）。`Require ip` は Apache に最初から入っている機能（`mod_authz_host`）で、追加のモジュールは要らない。どちらも設定の読み直し（`apachectl graceful`）で、止めずに入れられる |
| 3 | Apache で絞ると、**パス単位**（例: `/admin` だけ）で絞れ、**静的なファイルも含めて** Rails に届く前に止まる。拒否はアクセスのログとエラーのログに残る |
| 4 | Apache が受けるのは HTTP(S) だけなので、SSH などのほかのポートは絞れない（それは [OS](./access-restriction-os-firewall.md) で） |

## Apache 2.4 の許可の仕組み（要点）

| 要素 | 内容 |
|---|---|
| `Require ip <IP や CIDR>` | 接続元の IP が当てはまれば許可 |
| `Require env <環境変数>` | 環境変数が設定されていれば許可。国の判定（`mod_maxminddb`）と組み合わせる |
| `<RequireAny>` | 中のどれか 1 つが当てはまれば許可（「許可する IP か、日本」に使う） |
| `<RequireAll>` | 中のすべてが当てはまれば許可 |
| 置き場所 | `<Location>`（URL のパス）、`<Directory>`（ファイルの置き場所）、`<VirtualHost>` の中。Passenger が動かす Rails の URL には `<Location>` を使う |
| 判定の時点 | Passenger がリクエストを Rails に渡すより前。拒否したリクエストは Rails に届かない |
| 拒否したとき | 403 を返し、エラーのログに `AH01630: client denied by server configuration` が出る |

## 手順 1: 許可する IP の一覧（補助）を用意する（`Require ip`）

国の判定（手順 2）と組み合わせて使う。国の判定のモジュールを用意する前に、この一覧だけで先に絞っておくこともできるが、それでは国内の利用者まで止まるので、要件を満たすのは手順 2 まで入れた後になる。

### 許可する IP のファイル

許可する IP は、別のファイルにまとめて、使う場所から読み込む。`/etc/httpd/conf.d/` に置くと、そこにある `*.conf` は自動で読み込まれてしまうので、別の場所に置く。

```bash
sudo mkdir -p /etc/httpd/access
sudo tee /etc/httpd/access/allow-ip.conf <<'EOF'
# 許可する IP（Require ip の行として書く）
Require ip 203.0.113.10        # 例: 事務所
Require ip 198.51.100.0/24     # 例: 保守の委託先
Require ip 127.0.0.1 ::1       # 同じマシンの中
EOF
```

### 使う場所

```apache
# 例: /etc/httpd/conf.d/ssl.conf などの、対象の <VirtualHost *:443> の中

# 特定のパスだけを絞る
<Location "/admin">
    <RequireAny>
        Include /etc/httpd/access/allow-ip.conf
    </RequireAny>
</Location>
```

サイト全体を絞るなら `<Location "/">` にする。

### 反映と確認

```bash
sudo apachectl configtest      # Syntax OK を確かめる
sudo apachectl graceful        # 止めずに読み直す

curl -sI https://<ホスト名>/admin | head -1      # 許可していない所からは 403
sudo tail -f /var/log/httpd/ssl_error_log | grep AH01630
```

## 手順 2: 国で絞る（`mod_maxminddb`）

### 全体の流れ

| # | 作業 | 内容 |
|---|---|---|
| 1 | MaxMind のアカウント | 無料のアカウントを作り、ライセンスキーを発行する。GeoLite2 の利用条件を確認する |
| 2 | データベースの取得と更新 | `geoipupdate` で `GeoLite2-Country.mmdb` を取得し、cron で定期的に更新する |
| 3 | `libmaxminddb` | データベースを読むライブラリ。パッケージがあればそれを、なければソースから入れる |
| 4 | `mod_maxminddb` | Apache のモジュール。ソースからビルドする |
| 5 | Apache の設定 | 国の判定を環境変数に入れ、`Require` で使う |

### 1・2. データベースの取得と更新（geoipupdate）

MaxMind の `geoipupdate`（v8.0.0、2026-07）は、GitHub のリリースに RPM がある。

```bash
# RPM を GitHub のリリースから取得して入れる（版は最新に合わせる）
sudo yum install -y https://github.com/maxmind/geoipupdate/releases/download/v8.0.0/geoipupdate_8.0.0_linux_amd64.rpm

sudo tee /etc/GeoIP.conf <<'EOF'
AccountID <アカウントの ID>
LicenseKey <ライセンスキー>
EditionIDs GeoLite2-Country
DatabaseDirectory /usr/share/GeoIP
EOF
sudo chmod 600 /etc/GeoIP.conf

sudo mkdir -p /usr/share/GeoIP
sudo geoipupdate -v
ls -l /usr/share/GeoIP/GeoLite2-Country.mmdb

# 週 2 回の更新に合わせ、毎日取りに行く（新しくなっていなければ何もしない）
echo '23 5 * * * root /usr/bin/geoipupdate && /usr/sbin/apachectl graceful' | sudo tee /etc/cron.d/geoipupdate
```

`mod_maxminddb` がデータベースを読み直すのは Apache の読み直しのときなので、更新の後に `apachectl graceful` を実行する。

### 3. libmaxminddb

```bash
yum info libmaxminddb-devel    # パッケージがあるか
```

パッケージがあれば `sudo yum install -y libmaxminddb libmaxminddb-devel`。なければソースから入れる（1.14.1、2026-09）。

```bash
sudo yum install -y gcc make
curl -fsSLO https://github.com/maxmind/libmaxminddb/releases/download/1.14.1/libmaxminddb-1.14.1.tar.gz
tar -xzf libmaxminddb-1.14.1.tar.gz && cd libmaxminddb-1.14.1
./configure && make && sudo make install          # /usr/local に入る
echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/usr-local.conf
sudo ldconfig
```

### 4. mod_maxminddb（1.3.0、2025-05）

```bash
sudo yum install -y httpd-devel      # apxs（Apache のモジュールのビルドの道具）
curl -fsSLO https://github.com/maxmind/mod_maxminddb/releases/download/1.3.0/mod_maxminddb-1.3.0.tar.gz
tar -xzf mod_maxminddb-1.3.0.tar.gz && cd mod_maxminddb-1.3.0
# libmaxminddb をソースから入れたなら、/usr/local の場所を教える
PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure --with-apxs=/usr/bin/apxs
make && sudo make install

ls /usr/lib64/httpd/modules/mod_maxminddb.so
grep -r maxminddb_module /etc/httpd/conf /etc/httpd/conf.modules.d   # LoadModule の行があるか
```

`LoadModule` の行が足されていなければ、自分で足す。

```bash
echo 'LoadModule maxminddb_module modules/mod_maxminddb.so' | sudo tee /etc/httpd/conf.modules.d/10-maxminddb.conf
```

### 5. Apache の設定

`mod_maxminddb` の README の「国で許可する」例に沿った形。国の判定は、`SetEnvIf` より前に行われる。

```apache
# /etc/httpd/conf.d/maxminddb.conf（サーバー全体の設定）
<IfModule mod_maxminddb.c>
    MaxMindDBEnable On
    MaxMindDBFile COUNTRY_DB /usr/share/GeoIP/GeoLite2-Country.mmdb
    MaxMindDBEnv MM_COUNTRY_CODE COUNTRY_DB/country/iso_code
    SetEnvIf MM_COUNTRY_CODE ^JP$ FROM_JAPAN
</IfModule>
```

```apache
# 対象の <VirtualHost *:443> の中
<Location "/">
    <RequireAny>
        Include /etc/httpd/access/allow-ip.conf
        Require env FROM_JAPAN
    </RequireAny>
</Location>

# Let's Encrypt の確認は、どこからでも受け付ける（下の「気を付けること」）
<Location "/.well-known/acme-challenge/">
    Require all granted
</Location>
```

| 点 | 内容 |
|---|---|
| 判定できなかった IP | データベースに国がない IP では `MM_COUNTRY_CODE` が設定されず、`FROM_JAPAN` も付かないので拒否になる |
| `Require` の置き場所 | `<Location>`・`<Directory>`・`<Files>` の中に書く（README の注意） |
| `SetEnvIf` の代わり | `Require expr "%{ENV:MM_COUNTRY_CODE} == 'JP'"` でも書ける |

### ログに国を残す

```apache
# 既存の LogFormat の最後に国を足した形の例
LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %{MM_COUNTRY_CODE}e" combined_country
CustomLog logs/ssl_access_log combined_country
```

## 外す（元に戻す）

| 範囲 | やり方 |
|---|---|
| 制限だけ外す | `<Location>` の中の `<RequireAny>` をコメントにして `apachectl graceful` |
| 国の判定ごと外す | `/etc/httpd/conf.d/maxminddb.conf` と `10-maxminddb.conf` を `.disabled` などに名前を変えて `apachectl graceful` |

## 気を付けること

| 点 | 内容 |
|---|---|
| **Let's Encrypt の更新** | Let's Encrypt は**複数の国から**確認の接続（HTTP-01。80 番の `/.well-known/acme-challenge/`）を行う。80 番のサイト全体を国で絞ると、証明書の更新が失敗する。上の例のように、このパスだけは `Require all granted` にする（今は certbot の webroot で更新している） |
| 位置の判定は完全ではない | 海外にいる日本の利用者、VPN、海外の外形監視のサービス、外部サービスからの通知（webhook）は「日本以外」になりうる。必要な相手は `allow-ip.conf` に足す |
| 接続そのものは届く | Apache は接続を受けてから 403 を返す。接続の数を減らしたいなら、[OS](./access-restriction-os-firewall.md) で絞る |
| 前段を置いた場合 | 今は前段がないので、接続元の IP がそのまま利用者の IP になる。将来、前段（ロードバランサーや CDN）を置くと、接続元が前段になるので `mod_remoteip` で利用者の IP に直す必要がある |
| HTTP（80 番）の扱い | HTTPS へ転送しているだけなら、80 番は絞らなくてよい（転送の先で絞られる）。80 番の仮想ホストにも同じ制限を入れるなら、`/.well-known/acme-challenge/` を開けておく |
| ビルドしたモジュール | `mod_maxminddb` は Apache の版に合わせてビルドしたもの。Apache のパッケージを大きく更新したら、作り直しが要ることがある |

## 決めること

| # | 論点 | 選択肢 |
|---|---|---|
| A1 | 絞る範囲 | サイト全体 / 特定のパス（`/admin` など） |
| A2 | 国の判定のデータベース | GeoLite2 Country（無料。勧める） / 有料の GeoIP2 Country（精度と更新の頻度が上がる） |
| A3 | 拒否したときの応答 | 403（既定） / 404 などに見せかける（`ErrorDocument` や mod_rewrite） |
| A4 | 許可する IP の一覧 | 事務所、保守の委託先、監視、外部サービスなど |

## 参考

- [Apache の Access Control](https://httpd.apache.org/docs/2.4/howto/access.html)、[mod_authz_core](https://httpd.apache.org/docs/2.4/mod/mod_authz_core.html)（`Require`、`RequireAny`）
- [maxmind/mod_maxminddb](https://github.com/maxmind/mod_maxminddb)（ビルドの手順、「国で許可する」例）
- [maxmind/libmaxminddb](https://github.com/maxmind/libmaxminddb)、[maxmind/geoipupdate](https://github.com/maxmind/geoipupdate)
- [GeoLite2 の無料のデータベース](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data)（アカウント、ライセンスキー、更新の頻度、利用条件）
- [Let's Encrypt のチャレンジの種類](https://letsencrypt.org/docs/challenge-types/)
