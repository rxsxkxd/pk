#!/usr/bin/env python3
"""タイムゾーン差異のドライバ検証（Python / PyMySQL）— 収集のみ。

本スクリプトは観測した事実を reports/python.json へ書き出すだけであり、
合否の判定とレポート生成は行わない。判定は generate_report.rb が担当する。

PyMySQL はサーバーへ SET time_zone を発行せず、タイムゾーン層も持たない。
DATETIME / TIMESTAMP は naive な datetime（tzinfo が None）として返るため、
差の吸収はアプリケーション側の責務になる。本スクリプトでは接続先のセッション
time_zone に対応する tzinfo をアプリ側で付与し、その結果を記録する。
"""
import json
import os
from datetime import datetime, timedelta, timezone

import pymysql

SQL_ROWS = "SELECT id, ts, UNIX_TIMESTAMP(ts) AS server_epoch FROM t ORDER BY id"
SQL_WHERE = "SELECT COUNT(*) FROM t WHERE ts >= '2026-09-03 00:00:00'"
SQL_GROUPS = "SELECT COUNT(*) FROM (SELECT DATE(ts) FROM t GROUP BY DATE(ts)) g"

# 接続先のセッション time_zone に対応する tzinfo。
UTC = timezone.utc
JST = timezone(timedelta(hours=9))
TZ_LABEL = {UTC: "UTC", JST: "+09:00"}


def connect(host):
    return pymysql.connect(
        host=host,
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ.get("MYSQL_USER", "root"),
        password=os.environ["MYSQL_PWD"],
        database=os.environ.get("MYSQL_DATABASE", "tzcheck"),
        charset="utf8mb4",
    )


def collect_read(label, host, tzinfo):
    """読み取り値をアプリ側で解釈した結果を収集する。"""
    conn = connect(host)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT @@session.time_zone")
            session_tz = cur.fetchone()[0]
            section = f"{label} / アプリ側で {TZ_LABEL[tzinfo]} を付与"
            detail = f"session_time_zone={session_tz}"

            cur.execute(SQL_ROWS)
            out = []
            for id_, ts, server_epoch in cur.fetchall():
                # PyMySQL が返すのは naive。アプリ側で tzinfo を付けて絶対時刻にする。
                aware = ts.replace(tzinfo=tzinfo)
                out.append({
                    "section": section, "detail": detail, "id": id_,
                    "driver_value": f"{ts} (tzinfo={ts.tzinfo})",
                    "driver_unix": int(aware.timestamp()),
                    "server_unix": server_epoch,
                })
            return out
    finally:
        conn.close()


def collect_server_side(label, host, setting):
    """サーバー側で確定する結果を収集する。"""
    conn = connect(host)
    try:
        with conn.cursor() as cur:
            cur.execute(SQL_WHERE)
            where_matched = cur.fetchone()[0]
            cur.execute(SQL_GROUPS)
            date_groups = cur.fetchone()[0]
        return {
            "label": label, "setting": setting,
            "where_matched": where_matched, "date_groups": date_groups,
        }
    finally:
        conn.close()


def main():
    source_host = os.environ.get("SOURCE_HOST", "source")
    replica_host = os.environ.get("REPLICA_HOST", "replica")

    collection = {
        "schema_version": 1,
        "language": "Python",
        "driver": f"PyMySQL {pymysql.__version__}",
        "timezone_layer": "なし（naive な `datetime` を返す。付与はアプリ側の責務）",
        "issues_set_time_zone": False,
        "setting_label": "付与する tzinfo",
        "collected_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        # 接続先のセッション time_zone に対応する tzinfo を付与する。
        "read_results": (
            collect_read("source", source_host, UTC)
            + collect_read("replica", replica_host, JST)
        ),
        "contrast": {
            "title": "レプリカの naive な値へ誤って UTC を付与した場合",
            "results": collect_read("replica", replica_host, UTC),
        },
        # PyMySQL にはタイムゾーン設定がないため、アプリ側の付与を変えても
        # サーバー側の結果が変わらないことを示す。
        "server_side": [
            collect_server_side("source", source_host, "tzinfo=UTC を付与"),
            collect_server_side("source", source_host, "tzinfo=+09:00 を付与"),
            collect_server_side("replica", replica_host, "tzinfo=UTC を付与"),
            collect_server_side("replica", replica_host, "tzinfo=+09:00 を付与"),
        ],
    }

    directory = os.environ.get("REPORT_DIR", "/probe/reports")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "python.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(collection, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print(f"収集完了: {path}"
          f"（{len(collection['read_results'])} 行 / "
          f"対比 {len(collection['contrast']['results'])} 行 / "
          f"サーバー側 {len(collection['server_side'])} 件）")
    print("レポート生成: docker compose run --rm probe-report")


if __name__ == "__main__":
    main()
