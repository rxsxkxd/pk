#!/usr/bin/env bash
# タイムゾーン差異のレプリケーション検証用ローカル環境のセットアップ。
# docker compose up -d の後に 1 回だけ実行する。冪等に作られており、再実行しても壊れない。
#
# 実施すること:
#   1. mysql.time_zone_* テーブルのロード（RDS は事前ロード済みだが素の MySQL は空である）
#   2. レプリカの time_zone を Asia/Tokyo に設定（SET PERSIST で再起動後も維持する）
#   3. レプリケーションユーザーの作成とレプリケーション開始
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo '.env がない。cp .env.example .env を先に実行する。' >&2; exit 2; }
# shellcheck disable=SC1091
source .env
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD が .env に定義されていない}"

REPL_USER=repl
REPL_PASSWORD="${MYSQL_ROOT_PASSWORD}-repl"

# コンテナ内で SQL を実行する。パスワードは MYSQL_PWD で渡し、コマンド引数に出さない。
run_sql() {
  local service=$1; shift
  docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$service" \
    mysql -uroot --batch --skip-column-names "$@"
}

echo '==> 1. mysql.time_zone_* をロードする'
for service in source replica; do
  # イメージに tzdata が含まれない場合は明確に失敗させる（黙って空ロードにしない）。
  if ! docker compose exec -T "$service" test -d /usr/share/zoneinfo; then
    echo "    $service のイメージに /usr/share/zoneinfo がない。" >&2
    echo "    ホストの zoneinfo をマウントするか、イメージに tzdata を導入する必要がある。" >&2
    exit 1
  fi
  # mysql_tzinfo_to_sql は一部のファイルに警告を出すが、ロード自体は成功する。
  docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$service" \
    bash -c 'mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql -uroot mysql'
  loaded=$(run_sql "$service" -e 'SELECT COUNT(*) FROM mysql.time_zone_name')
  echo "    $service: time_zone_name = $loaded 件"
  [[ "$loaded" -gt 0 ]] || { echo "    $service へのタイムゾーンテーブルのロードに失敗した" >&2; exit 1; }
done

echo '==> 2. レプリカの time_zone を Asia/Tokyo にする'
# SET PERSIST は即時に GLOBAL へ反映し、かつ mysqld-auto.cnf へ書き出して再起動後も維持する。
run_sql replica -e "SET PERSIST time_zone = 'Asia/Tokyo'"
run_sql replica -e "SELECT CONCAT('    replica global time_zone = ', @@global.time_zone)"
run_sql source  -e "SELECT CONCAT('    source  global time_zone = ', @@global.time_zone)"

echo '==> 3. レプリケーションユーザーを作成する'
run_sql source -e "
  CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASSWORD}';
  ALTER USER '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASSWORD}';
  GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
"

echo '==> 4. レプリケーションを開始する'
# 既に動いている場合に備えて一度停止してから設定する（再実行時のため）。
run_sql replica -e 'STOP REPLICA' 2>/dev/null || true
# MySQL 8.4 では CHANGE MASTER TO / START SLAVE は削除済みのため新構文を使う。
# caching_sha2_password を TLS なしで使うため GET_SOURCE_PUBLIC_KEY を有効にする。
run_sql replica -e "
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='source',
    SOURCE_PORT=3306,
    SOURCE_USER='${REPL_USER}',
    SOURCE_PASSWORD='${REPL_PASSWORD}',
    SOURCE_AUTO_POSITION=1,
    GET_SOURCE_PUBLIC_KEY=1;
  START REPLICA;
"

echo '==> 5. レプリケーションの状態を確認する'
for _ in $(seq 1 20); do
  state=$(run_sql replica -e "
    SELECT CONCAT(
      IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_connection_status LIMIT 1),'NONE'),
      ' / ',
      IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_applier_status LIMIT 1),'NONE'))")
  echo "    IO / SQL = $state"
  [[ "$state" == 'ON / ON' ]] && break
  sleep 2
done

if [[ "${state:-}" != 'ON / ON' ]]; then
  echo 'レプリケーションが開始しなかった。次で詳細を確認する:' >&2
  echo '  docker compose exec replica mysql -uroot -p -e "SHOW REPLICA STATUS\G"' >&2
  exit 1
fi

echo
echo 'セットアップ完了。README.md の「検証手順」へ進む。'
