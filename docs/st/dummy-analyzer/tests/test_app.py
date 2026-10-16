"""dummy-analyzer/src/app.py のテスト（標準のライブラリだけ）。

    python3 -m unittest discover -s dummy-analyzer/tests
"""

import base64
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import app  # noqa: E402


def call(query=None, env=None, body="img", b64=False, headers=None):
    slept = []
    event = {
        "queryStringParameters": query,
        "headers": headers or {"Content-Type": "application/octet-stream"},
        "body": base64.b64encode(body.encode()).decode() if b64 else body,
        "isBase64Encoded": b64,
    }
    with mock.patch.dict(os.environ, env or {}, clear=True):
        res = app.handler(event, None, sleep=slept.append)
    return res, slept


class TestHandler(unittest.TestCase):
    def test_default_is_pass_without_delay(self):
        res, slept = call()
        self.assertEqual(res["statusCode"], 200)
        self.assertEqual(json.loads(res["body"])["result"], "PASS")
        self.assertEqual(slept, [0.0])

    def test_environment_sets_the_default(self):
        res, slept = call(env={"DUMMY_RESULT": "reject", "DUMMY_DELAY": "7"})
        self.assertEqual(json.loads(res["body"])["result"], "REJECT")
        self.assertEqual(slept, [7.0])

    def test_query_overrides_the_environment(self):
        res, slept = call(query={"result": "RETRY", "delay": "0.5"}, env={"DUMMY_RESULT": "REJECT", "DUMMY_DELAY": "7"})
        self.assertEqual(json.loads(res["body"])["result"], "RETRY")
        self.assertEqual(slept, [0.5])

    def test_status_returns_an_empty_error(self):
        res, _ = call(query={"status": "500"})
        self.assertEqual((res["statusCode"], res["body"]), (500, ""))

    def test_garbage_body_is_not_json(self):
        res, _ = call(query={"body": "garbage"})
        self.assertEqual(res["statusCode"], 200)
        with self.assertRaises(json.JSONDecodeError):
            json.loads(res["body"])

    def test_bad_settings_are_400(self):
        for query in ({"result": "MAYBE"}, {"delay": "51"}, {"delay": "-1"}, {"delay": "x"}, {"status": "99"}, {"body": "xml"}):
            res, slept = call(query=query)
            self.assertEqual(res["statusCode"], 400, query)
            self.assertEqual(slept, [], query)

    def test_logs_the_size_but_not_the_api_key(self):
        with mock.patch("builtins.print") as printed:
            call(body="abcd", b64=True, headers={"X-Api-Key": "secret", "Content-Type": "application/octet-stream"})
        line = printed.call_args.args[0]
        log = json.loads(line)
        self.assertEqual((log["receivedBytes"], log["hasApiKey"]), (4, True))
        self.assertNotIn("secret", line)


if __name__ == "__main__":
    unittest.main()
