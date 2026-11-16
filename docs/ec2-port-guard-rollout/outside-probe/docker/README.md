# Docker の定義: 海外からの確認の拠点（チェック用のクライアント。Amazon Linux 2023）

> 位置付け: [海外からの確認の拠点](../../outside-probe.md) を、手元で再現するための定義。**道具の動作の確認用**で、手元のコンテナからの接続は「海外の IP」にはならない（接続元は Docker のネットワークの IP）。本物の確認は、AWS の別のリージョンのインスタンス（[EC2 Image Builder の定義](../image-builder/README.md) の AMI、またはテンプレートの案）で行う。**まだビルドしていない**。
>
> 作成日: 2026-10-29

## 中身

| ファイル | 内容 |
|---|---|
| `Dockerfile` | AL2023 のコンテナイメージ（digest で固定）に、`python3`・`nmap-ncat`（`nc`）・`openssl` を入れ、`port-guard-probe` を `/usr/local/bin/` に置く |
| `compose.yaml` | 手元の `al2-instance` の compose が作るネットワーク（`al2-instance_default`）にもつなぐ |
| `../port-guard-probe` | 確認の処理の本体（Docker と Image Builder の両方で使う。使い方は [海外からの確認の拠点](../../outside-probe.md#port-guard-probe-の使い方)） |

## 使い方

```bash
# 先に、相手の al2-instance を起動しておく（同じネットワークにつなぐため）
(cd ../../al2-instance && docker compose up -d)

cd port-guard-rollout/outside-probe/docker
docker compose build
docker compose up -d
docker compose exec outside-probe port-guard-probe al2-instance 80:http 443:tls
```

## 相手のつなぎ方（2 通り）

| つなぎ方 | 相手 | 接続元（al2-instance から見た IP） | 向いている確認 |
|---|---|---|---|
| **同じネットワーク**（勧める） | `al2-instance`（compose のサービス名）の 80・443 番 | このコンテナの IP（`172.x.x.x` など。日本の集合にも許可する IP の一覧にも入らない） | 遮断の前は `reachable`、遮断の後は `timeout` になることを確かめる（破棄の経路をそのまま試せる） |
| 手元に転送したポート | `host.docker.internal` の 8080・8443 番 | Docker Desktop の仮想マシン（`192.168.65.1`） | `al2-instance` で手元からの接続を許可しているか（`allow.txt` の `192.168.65.1`）の確認。Docker Desktop の転送の仕組みは TCP の接続を受け付けてしまうので、`tcp` では判定できない（`http`・`tls` を使う） |

```bash
# 同じネットワーク: 遮断の後は timeout になるはず
docker compose exec outside-probe port-guard-probe al2-instance 80:http 443:tls --timeout 3

# 手元に転送したポート
docker compose exec outside-probe port-guard-probe host.docker.internal 8080:http 8443:tls
```

`port-guard-probe` の終了コードは、すべて届けば 0、届かないものがあれば 1。

## 本物の拠点との違い

| 項目 | この定義 | 本物の拠点（AWS の別のリージョン） |
|---|---|---|
| 接続元の IP | Docker のネットワークの IP | 米国のリージョンのパブリック IP（日本の範囲に入らない） |
| 入り方 | `docker compose exec` | SSM（Session Manager・Run Command） |
| `python3` | 入れる（コンテナのイメージにはない） | AL2023 の AMI に最初から入っている |

## 取得するデータ（ビルドするとき）

AL2023 のコンテナイメージは手元にあるもの（digest で固定）を使う。取得するのは、dnf のリポジトリのメタデータ（約 85 MB）と、`python3`・`nmap-ncat`・`openssl` のパッケージ（数十 MB の見込み）。
