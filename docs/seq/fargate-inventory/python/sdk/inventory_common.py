"""棚卸しツールの Python 版（SDK 版・CLI 版）で共通に使う部分。

正本は docs/seq/_common/python/inventory_common.py。各ツールにあるのは sync-common.sh で写したものなので、直接編集しない。
AWS の呼び出しは同じディレクトリの aws_client.py（SDK 版は boto3、CLI 版は aws コマンド）が受け持つ。
どちらも AWS CLI の JSON 出力と同じ形のデータを返すので、ツール側の service.py は SDK 版と CLI 版で同じものを使う。

ツール側の service.py で定義するもの:
  TOOL              使い方の表示に使うコマンド名
  SNAPSHOT_OPTIONS  一覧取得（snapshot）のオプション [(オプション名, 説明)]。どれも繰り返し指定できる文字列
  snapshot(ctx, opts)  一覧取得。レコードを順に返す。opts はオプション名（先頭の -- を除き - を _ にしたもの）→ 値のリスト
  DETAIL_KINDS      詳細取得（detail）の種類 → (当てはまるレコード種別のタプル, 関数(ctx, record))
"""

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone

from aws_client import Aws, AwsError

ISO_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$")


def utc_iso(value):
    """日時を UTC の秒単位（YYYY-MM-DDTHH:MM:SSZ）にそろえる。datetime、ISO 8601 の文字列、エポック秒を受け付ける。"""
    if value is None:
        return None
    if isinstance(value, datetime):
        dt = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(int(value), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    m = ISO_RE.match(value)
    if not m:
        return value
    base = datetime.strptime(m[1], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    tz = m[3]
    offset = 0 if tz == "Z" else (-1 if tz[0] == "-" else 1) * (int(tz[1:3]) * 3600 + int(tz[-2:]) * 60)
    return datetime.fromtimestamp(int(base.timestamp()) - offset, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_iso(value):
    """エポック秒の文字列（SQS などの属性）を UTC にする。"""
    return None if value is None else utc_iso(int(float(value)))


def now_iso():
    return utc_iso(datetime.now(timezone.utc))


def tags_object(tags):
    """タグの配列（Key/Value または key/value）をオブジェクトにする。"""
    return {t.get("Key", t.get("key")): t.get("Value", t.get("value")) for t in tags or []}


def chunked(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def error_entry(error):
    return {"operation": error.operation, "code": error.code, "message": error.message}


class Context:
    """一覧取得・詳細取得の間で持ち回る状態。"""

    def __init__(self, aws, interval=0.0):
        self.aws = aws
        self.interval = interval
        self.cache = {}
        self.common = {}

    def call(self, service, operation, params=None, region=None, paginate=True):
        """AWS の API を呼ぶ。詳細取得では 1 回ごとに間隔を空ける。paginate=False なら最初のページだけを取る。"""
        if self.interval:
            time.sleep(self.interval)
        return self.aws.call(service, operation, params or {}, region, paginate)

    def call_or_none(self, codes, service, operation, params=None, region=None):
        """「設定が無い」ことをエラーで返す API 用。codes のエラーコードなら None を返す。"""
        try:
            return self.call(service, operation, params, region)
        except AwsError as e:
            if e.code in codes:
                return None
            raise

    def cached(self, key, fn):
        """同じキーの結果は 1 回の実行で 1 回だけ取る。"""
        if key not in self.cache:
            self.cache[key] = fn()
        return self.cache[key]

    def record(self, record_type, fields, errors=()):
        """共通の項目を付けてレコードにする。fields に region があれば、そちらを使う。"""
        return {"record_type": record_type, **self.common, **fields, "errors": list(errors)}


def _json_default(value):
    if isinstance(value, datetime):
        return utc_iso(value)
    raise TypeError(f"JSON にできない値: {value!r}")


def write(record):
    sys.stdout.write(json.dumps(record, ensure_ascii=False, separators=(",", ":"), default=_json_default) + "\n")


def main(service, argv):
    parser = argparse.ArgumentParser(prog=service.TOOL)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("snapshot", help="まとめて取得できる API だけで一覧を取る")
    dests = []
    for name, help_text in service.SNAPSHOT_OPTIONS:
        dest = name.lstrip("-").replace("-", "_")
        p.add_argument(name, dest=dest, action="append", default=[], help=help_text)
        dests.append(dest)

    p = sub.add_parser("detail", help="標準入力のレコードに、リソースごとの詳細を足す")
    p.add_argument("--with", dest="kinds", required=True, help=",".join(service.DETAIL_KINDS) or "（なし）")
    p.add_argument("--interval", type=float, default=0.2)
    p.add_argument("--max", type=int, default=100)

    args = parser.parse_args(argv)
    aws = Aws()
    try:
        if args.command == "snapshot":
            run_snapshot(service, aws, {d: getattr(args, d) for d in dests})
        else:
            run_detail(service, aws, args)
    except AwsError as e:
        sys.exit(f"{e.operation}: {e.code}: {e.message}")


def run_snapshot(service, aws, opts):
    ctx = Context(aws)
    account = aws.call("sts", "get_caller_identity", {}, None)["Account"]
    ctx.common = {"account_id": account, "region": aws.region, "collected_at": now_iso()}
    for record in service.snapshot(ctx, opts):
        write(record)


def run_detail(service, aws, args):
    kinds = args.kinds.split(",")
    for kind in kinds:
        if kind not in service.DETAIL_KINDS:
            sys.exit(f"不明な詳細の種類: {kind}")

    # 件数が多すぎるときは、絞り込み忘れとみなして止める
    records = [json.loads(line) for line in sys.stdin if line.strip()]
    if len(records) > args.max:
        sys.exit(f"入力が {len(records)} 件あり、上限（--max {args.max}）を超えています。jq で絞り込むか、--max を上げてください")

    ctx = Context(aws, args.interval)
    for record in records:
        details = {}
        errors = []
        for kind in kinds:
            types, fn = service.DETAIL_KINDS[kind]
            if record.get("record_type") not in types:
                continue
            try:
                details[kind] = fn(ctx, record)
            except AwsError as e:
                details[kind] = None
                errors.append(error_entry(e))
        write({**record, "details_collected_at": now_iso(), "details": details,
               "errors": (record.get("errors") or []) + errors})
