"""Image analysis server stub (Python) for checking the ticket API on AWS Lambda: the Lambda entry point.
Runs behind a Lambda Function URL (payload format 2.0). This file parses and checks the request (route,
Content-Type, body; see ../DESIGN.md 3) and logs it; the API key rule and judging the image are analyzer.py. Same
behavior as ../node/index.mjs; both are checked against ../testdata/cases.json. No dependencies; boto3
comes with the Lambda runtime. Needs Python 3.12+ (the `type` statement)."""

import base64
import functools
import json
import os
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from http import HTTPStatus
from typing import Any, Self, TypedDict

from analyzer import ApiKey, Auth, NoApiKey, analyze

type Event = Mapping[str, Any]
type LogFields = dict[str, Any]
type Logger = Callable[[LogFields], None]


class Response(TypedDict):
    statusCode: int
    headers: dict[str, str]
    body: str


def handler(event: Event, context: object) -> Response:
    """Lambda のハンドラー。初回の呼び出し時に API キーを読み込み、以降は使い回す。"""
    return _stub_from_env()(event)


@functools.cache
def _stub_from_env() -> "Stub":
    return Stub(load_auth(os.environ))


def load_auth(env: Mapping[str, str], log: Logger | None = None) -> Auth:
    """認証の決まりを選ぶ。STUB_AUTH=none を明示したときだけ API キーを確かめない（VPC 内で SG だけで許可する場合）。
    それ以外は API キーが必須（設定漏れで、公開した Function URL のスタブが誰でも呼べる状態にならないように）。"""
    match env.get("STUB_AUTH", "api-key"):
        case "none":
            (log or print_log)({"level": "WARN", "msg": "api key check is disabled (STUB_AUTH=none)"})
            return NoApiKey()
        case "api-key":
            return ApiKey(load_api_key(env))
        case other:
            raise RuntimeError(f"STUB_AUTH must be api-key or none, got {other!r}")


def load_api_key(env: Mapping[str, str]) -> str:
    """Parameter Store の SecureString から API キーを読み込む（APP_ENV=local のときだけ STUB_API_KEY の平文を使う）。"""
    if name := env.get("API_KEY_PARAMETER_NAME"):
        import boto3  # type: ignore[import-not-found]  # Lambda のランタイムに同梱。ローカルとテストでは読み込まない

        parameter = boto3.client("ssm").get_parameter(Name=name, WithDecryption=True)["Parameter"]
        if value := parameter.get("Value"):
            return str(value)
    elif env.get("APP_ENV") == "local" and (value := env.get("STUB_API_KEY")):
        return value
    raise RuntimeError("API_KEY_PARAMETER_NAME is not set")


@dataclass(frozen=True)
class Request:
    """スタブが見るリクエストの項目（Function URL のイベントから取り出したもの）。"""

    method: str
    path: str
    api_key: str
    content_type: str  # パラメーター（; 以降）を外し、小文字にしたもの
    body: bytes
    request_id: str | None

    @classmethod
    def from_event(cls, event: Event) -> Self:
        context = event.get("requestContext") or {}
        headers = {name.lower(): value for name, value in (event.get("headers") or {}).items()}
        body: str = event.get("body") or ""
        return cls(
            method=context.get("http", {}).get("method", ""),
            path=event.get("rawPath", ""),
            api_key=headers.get("x-api-key", ""),
            content_type=headers.get("content-type", "").partition(";")[0].strip().lower(),
            # octet-stream のボディは、Function URL が base64 で渡す
            body=base64.b64decode(body) if event.get("isBase64Encoded") else body.encode(),
            request_id=context.get("requestId"),
        )


@dataclass(frozen=True)
class Outcome:
    """応答（ステータスと本文）と、ログに足す項目。"""

    status: HTTPStatus
    body: dict[str, Any]
    log_fields: LogFields = field(default_factory=dict)

    def response(self) -> Response:
        return {
            "statusCode": self.status.value,
            "headers": {"content-type": "application/json"},
            "body": _compact_json(self.body),
        }


NOT_FOUND = Outcome(HTTPStatus.NOT_FOUND, {"error": "not found"})
INVALID_API_KEY = Outcome(HTTPStatus.UNAUTHORIZED, {"error": "invalid api key"})
EMPTY_BODY = Outcome(HTTPStatus.BAD_REQUEST, {"error": "empty body"})


class Stub:
    """Function URL のイベントを受け取り、リクエストを確かめて応答を返す（ログ出力はテスト用に差し替え可能）。"""

    def __init__(self, auth: Auth, log: Logger | None = None) -> None:
        self._auth = auth
        self._log = log or print_log

    def __call__(self, event: Event) -> Response:
        request = Request.from_event(event)
        outcome = self.handle(request)
        line: LogFields = {"level": "INFO", "msg": "analyzed"}
        if request.request_id is not None:
            line["requestId"] = request.request_id
        self._log(line | {"status": outcome.status.value} | outcome.log_fields)
        return outcome.response()

    def handle(self, request: Request) -> Outcome:
        """仕様（../DESIGN.md 3.2）の順にリクエストを確かめ、通ったものだけ画像の判定（analyzer.py）に渡す。API キーの照合も analyzer.py。"""
        if request.method != "POST" or request.path != "/v1/analyze":
            return NOT_FOUND
        if not self._auth.matches(request.api_key):
            return INVALID_API_KEY
        if request.content_type != "application/octet-stream":
            error = {"error": "Content-Type must be application/octet-stream"}
            return Outcome(HTTPStatus.BAD_REQUEST, error, {"contentType": request.content_type})
        if not request.body:
            return EMPTY_BODY

        analysis = analyze(request.body)
        body = {
            "confidence": analysis.confidence,
            "detected": analysis.detected,
            "reason": analysis.reason,
            "result": analysis.result,
            "status": HTTPStatus.OK.value,
        }
        fields = {"bytes": analysis.size, "sha256": analysis.sha256, "result": analysis.result}
        return Outcome(HTTPStatus.OK, body, fields)


def _compact_json(value: Any) -> str:
    """Node の JSON.stringify と同じ、空白なしの JSON。"""
    return json.dumps(value, separators=(",", ":"))


def print_log(fields: LogFields) -> None:
    """1行の JSON ログを出す（画像の中身は出さない）。"""
    time = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    print(_compact_json({"time": time} | fields), flush=True)
