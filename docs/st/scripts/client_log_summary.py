#!/usr/bin/env python3
"""ブラウザと OS ごとの件数を、API のログから集計するサンプル（後処理用。標準ライブラリだけで動く）。

API は、QR 同梱発行 API・チケット発行 API の完了ログ（"msg":"request completed"）に、ブラウザが送った
User-Agent と Client Hints を "client" として加工せずに記録している（DESIGN.md 10章「ブラウザと OS の記録」）。
このスクリプトは、そのログを読んで User-Agent を解釈し、ブラウザ・OS ごとの件数とエラー数を表にする。

入力は標準入力から読む。1行に1つのログで、JSON の前に何が付いていてもよい:
  - Go 版:   {"time":...,"msg":"request completed",...}
  - Node 版: 2026-10-06T04:47:10.147Z<TAB><リクエスト ID><TAB>INFO<TAB>{"time":...}（Lambda が行頭に付ける）
  - aws logs tail の出力: 2026-10-06T04:47:10 <ストリーム名> {"time":...}

使い方の例:
  aws logs tail /aws/lambda/ticketqr-go-tickets --since 1d --filter-pattern '"request completed"' \\
    | python3 scripts/client_log_summary.py
  python3 scripts/client_log_summary.py --by os < exported.log   # OS ごとにまとめる
  python3 scripts/client_log_summary.py --by browser < exported.log
"""

import argparse
import json
import re
import sys
from collections import Counter

UPLOAD_ENDPOINTS = {"issue-inline", "issue"}

# Android の Chrome（110 以降）は User-Agent の OS を "Android 10; K" に固定している（本当の版は Client Hints だけ）。
REDUCED_ANDROID = re.compile(r"Android 10; K\)")
# iOS 26 以降の Safari は、User-Agent の OS を 18_x に固定している（Safari の Version/xx が iOS のメジャー版とほぼ一致）。
FROZEN_IOS_MAJOR = 18


def read_entries(lines):
    """各行から最初の JSON オブジェクトを取り出す（JSON の前の文字は読み飛ばす）。"""
    decoder = json.JSONDecoder()
    for line in lines:
        start = line.find("{")
        if start < 0:
            continue
        try:
            entry, _ = decoder.raw_decode(line[start:])
        except json.JSONDecodeError:
            continue
        if isinstance(entry, dict):
            yield entry


def platform_version(client):
    """Sec-CH-UA-Platform-Version（例: "13.0.0"）のメジャー版。届いていなければ None。"""
    m = re.match(r'"?(\d+)', client.get("secChUaPlatformVersion", ""))
    return m.group(1) if m else None


def parse_client(client):
    """client（User-Agent と Client Hints）を (OS, OS の版, ブラウザ, ブラウザの版) に解釈する。"""
    ua = client.get("userAgent", "")

    # iPhone / iPad（iOS のブラウザはすべて WebKit。Chrome は CriOS、Firefox は FxiOS、Edge は EdgiOS と名乗る）
    m = re.search(r"\((iPhone|iPad|iPod)[^)]*? OS (\d+)[_.](\d+)", ua)
    if m:
        os_name = "iPadOS" if m.group(1) == "iPad" else "iOS"
        os_major = int(m.group(2))
        os_version = f"{m.group(2)}.{m.group(3)}"
        for name, pattern in (("Chrome", r"CriOS/(\d+)"), ("Firefox", r"FxiOS/(\d+)"), ("Edge", r"EdgiOS/(\d+)")):
            b = re.search(pattern, ua)
            if b:
                if os_major == FROZEN_IOS_MAJOR:
                    os_version += "（26 以降の可能性あり）"
                return os_name, os_version, f"{name}（iOS）", b.group(1)
        safari = re.search(r"Version/(\d+)", ua)
        if safari:
            safari_major = int(safari.group(1))
            if os_major == FROZEN_IOS_MAJOR and safari_major >= 26:
                os_version = f"{safari_major}（推定。UA の OS は {m.group(2)}.{m.group(3)} に固定）"
            return os_name, os_version, "Safari", str(safari_major)
        return os_name, os_version, "WebView など", "-"

    # Android
    m = re.search(r"Android (\d+(?:\.\d+)?)", ua)
    if m:
        os_version = m.group(1)
        if REDUCED_ANDROID.search(ua):
            hinted = platform_version(client)
            os_version = hinted if hinted else "不明（UA は 10 に固定）"
        for name, pattern in (
            ("Samsung Internet", r"SamsungBrowser/(\d+)"),
            ("Edge", r"EdgA/(\d+)"),
            ("Firefox", r"Firefox/(\d+)"),
            ("Chrome", r"Chrome/(\d+)"),
        ):
            b = re.search(pattern, ua)
            if b:
                return "Android", os_version, name, b.group(1)
        return "Android", os_version, "その他", "-"

    # PC など（参考）
    for os_name, pattern in (("Windows", r"Windows NT"), ("macOS", r"Macintosh"), ("Linux", r"Linux")):
        if re.search(pattern, ua):
            for name, bp in (("Edge", r"Edg/(\d+)"), ("Firefox", r"Firefox/(\d+)"), ("Chrome", r"Chrome/(\d+)"),
                             ("Safari", r"Version/(\d+).*Safari")):
                b = re.search(bp, ua)
                if b:
                    return os_name, "-", name, b.group(1)
            return os_name, "-", "その他", "-"
    return "不明", "-", "不明" if ua else "（User-Agent なし）", "-"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--by", choices=["full", "os", "browser"], default="full",
                        help="まとめ方: full=OS・ブラウザの組み合わせ（既定）、os=OS と版、browser=ブラウザと版")
    args = parser.parse_args()

    requests, errors = Counter(), Counter()
    for entry in read_entries(sys.stdin):
        if entry.get("msg") != "request completed" or entry.get("endpoint") not in UPLOAD_ENDPOINTS:
            continue
        os_name, os_version, browser, browser_version = parse_client(entry.get("client") or {})
        key = {
            "full": (os_name, os_version, browser, browser_version),
            "os": (os_name, os_version),
            "browser": (browser, browser_version),
        }[args.by]
        requests[key] += 1
        if int(entry.get("status", 0)) >= 400:
            errors[key] += 1

    headers = {"full": ("OS", "OS の版", "ブラウザ", "ブラウザの版"), "os": ("OS", "OS の版"),
               "browser": ("ブラウザ", "ブラウザの版")}[args.by] + ("件数", "エラー（4xx/5xx）")
    print("\t".join(headers))
    for key, count in requests.most_common():
        print("\t".join((*key, str(count), str(errors[key]))))
    print(f"合計\t{sum(requests.values())} 件（エラー {sum(errors.values())} 件）", file=sys.stderr)


if __name__ == "__main__":
    main()
