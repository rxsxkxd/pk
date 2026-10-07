"""Same cases as the Node and Rust stubs: ../testdata/cases.json. Run: python3 -m unittest -v"""

import base64
import hashlib
import json
import unittest
from pathlib import Path
from typing import Any

from index import Event, Stub, load_api_key

CASES: list[dict[str, Any]] = json.loads((Path(__file__).parent.parent / "testdata/cases.json").read_text())["cases"]


def event(
    body: bytes,
    *,
    method: str = "POST",
    path: str = "/v1/analyze",
    api_key: str | None = "test-key",
    content_type: str = "application/octet-stream",
) -> Event:
    """テスト用の Function URL イベントを作る（octet-stream は Lambda が base64 で渡す）。"""
    headers = {"content-type": content_type} | ({"x-api-key": api_key} if api_key is not None else {})
    return {
        "rawPath": path,
        "headers": headers,
        "body": base64.b64encode(body).decode(),
        "isBase64Encoded": True,
        "requestContext": {"requestId": "t", "http": {"method": method}},
    }


def case_event(case: dict[str, Any]) -> Event:
    """共通のテストケース（キーは JSON のキャメルケース）からイベントを作る。省略された項目は event() の既定値。"""
    names = {"method": "method", "path": "path", "apiKey": "api_key", "contentType": "content_type"}
    options = {names[key]: value for key, value in case.items() if key in names}
    return event(bytes.fromhex(case["bodyHex"]), **options)


class SharedCases(unittest.TestCase):
    def test_cases(self) -> None:
        for case in CASES:
            with self.subTest(case["name"]):
                logs: list[dict[str, Any]] = []
                stub = Stub("test-key", logs.append)
                body = bytes.fromhex(case["bodyHex"])

                res = stub(case_event(case))

                self.assertEqual(res["statusCode"], case["status"], res["body"])
                self.assertEqual(len(logs), 1)
                if case["status"] == 200:
                    self.assertEqual(json.loads(res["body"])["valid"], case["valid"])
                    # The log proves the bytes arrived unchanged: same length and SHA-256 as what was sent.
                    self.assertEqual(logs[0]["bytes"], len(body))
                    self.assertEqual(logs[0]["sha256"], hashlib.sha256(body).hexdigest())


class Behavior(unittest.TestCase):
    def test_header_names_are_case_insensitive(self) -> None:
        stub = Stub("test-key", lambda _: None)
        ev = dict(event(bytes.fromhex("ffd8ff")))
        ev["headers"] = {"Content-Type": "application/octet-stream", "X-Api-Key": "test-key"}
        self.assertEqual(stub(ev)["statusCode"], 200)

    def test_same_response_body_and_log_as_node(self) -> None:
        logs: list[dict[str, Any]] = []
        res = Stub("test-key", logs.append)(event(bytes.fromhex("ffd8ff")))
        self.assertEqual(res["body"], '{"valid":true,"reason":"stub"}')
        self.assertEqual(list(logs[0]), ["level", "msg", "requestId", "status", "bytes", "sha256", "valid"])
        self.assertIs(type(logs[0]["status"]), int)

    def test_api_key_comes_from_stub_api_key_only_when_app_env_is_local(self) -> None:
        self.assertEqual(load_api_key({"APP_ENV": "local", "STUB_API_KEY": "k"}), "k")
        for env in ({}, {"STUB_API_KEY": "k"}, {"APP_ENV": "local", "STUB_API_KEY": ""}):
            with self.subTest(env=env), self.assertRaisesRegex(RuntimeError, "API_KEY_PARAMETER_NAME"):
                load_api_key(env)


if __name__ == "__main__":
    unittest.main()
