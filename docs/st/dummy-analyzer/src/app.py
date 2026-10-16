"""検証環境用のダミーの画像解析サーバー（Lambda の関数 URL）。

チケット QR API の解析クライアント（go/internal/analyzer/http.go）の動きを AWS 上で確かめるため、判定の結果・応答の
遅れ・失敗を、設定で選んで返す。画像は読まない（受け取った大きさだけをログに出す）。analyzer-stub（解析サーバーの
スタブ）とは別のもの。使い方は dummy-analyzer/README.md。

振る舞いは、関数の環境変数（既定）と、URL のクエリ（その要求だけ上書き）で決める:

    result  PASS / REJECT / RETRY                  返す判定（既定 PASS）
    delay   秒（0〜50。小数可）                     応答の前に待つ時間（既定 0）
    status  HTTP のステータス（200〜599）           200 以外なら、本文なしでそのステータスを返す（既定 200）
    body    json / garbage                          garbage なら、JSON でない本文を返す（既定 json）

環境変数の名前は DUMMY_RESULT・DUMMY_DELAY・DUMMY_STATUS・DUMMY_BODY。
"""

import base64
import json
import os
import time

RESULTS = ("PASS", "REJECT", "RETRY")
BODIES = ("json", "garbage")
MAX_DELAY = 50.0  # 関数のタイムアウト（60 秒）より短くする


class BadSetting(ValueError):
    pass


def settings(query):
    """環境変数とクエリから振る舞いを決める。値が正しくなければ BadSetting。"""

    def pick(name):
        return (query or {}).get(name) or os.environ.get("DUMMY_" + name.upper()) or ""

    result = pick("result").upper() or "PASS"
    if result not in RESULTS:
        raise BadSetting(f"result must be one of {', '.join(RESULTS)}: {result!r}")
    body = pick("body").lower() or "json"
    if body not in BODIES:
        raise BadSetting(f"body must be one of {', '.join(BODIES)}: {body!r}")
    try:
        delay = float(pick("delay") or 0)
        status = int(pick("status") or 200)
    except ValueError as e:
        raise BadSetting(str(e)) from e
    if not 0 <= delay <= MAX_DELAY:
        raise BadSetting(f"delay must be 0 to {MAX_DELAY:g} seconds: {delay}")
    if not 200 <= status <= 599:
        raise BadSetting(f"status must be 200 to 599: {status}")
    return {"result": result, "delay": delay, "status": status, "body": body}


def received_bytes(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return len(base64.b64decode(body))
    return len(body.encode())


def handler(event, context, sleep=time.sleep):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    try:
        s = settings(event.get("queryStringParameters"))
    except BadSetting as e:
        print(json.dumps({"msg": "dummy analyzer: bad setting", "error": str(e)}))
        return {"statusCode": 400, "headers": {"Content-Type": "text/plain"}, "body": str(e)}

    # ログ: 呼ばれた回数（やり直しの確認）と、届いたものの概要。画像そのものと x-api-key の値は出さない
    print(json.dumps({
        "msg": "dummy analyzer called",
        **s,
        "receivedBytes": received_bytes(event),
        "contentType": headers.get("content-type", ""),
        "hasApiKey": "x-api-key" in headers,
    }))
    sleep(s["delay"])

    if s["status"] != 200:
        return {"statusCode": s["status"], "body": ""}
    if s["body"] == "garbage":
        return {"statusCode": 200, "headers": {"Content-Type": "text/plain"}, "body": "not json"}
    # 本物の応答と同じ形（analyzer-stub/DESIGN.md 3.2）。API が見るのは result だけ
    out = {"confidence": 1.0, "detected": "dummy", "reason": "dummy analyzer", "result": s["result"], "status": 200}
    return {"statusCode": 200, "headers": {"Content-Type": "application/json"}, "body": json.dumps(out)}
