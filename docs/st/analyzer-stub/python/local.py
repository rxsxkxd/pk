"""Local server for the stub (not deployed): converts HTTP requests into Lambda Function URL events.
Run: python3 local.py  ->  POST http://localhost:8090/v1/analyze  (x-api-key: local-stub-key)"""

import base64
import os
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from index import Stub, load_api_key


class FunctionUrlAdapter(BaseHTTPRequestHandler):
    """HTTP のリクエストを Function URL のイベントにしてスタブに渡し、応答をそのまま返す。"""

    stub: Stub  # main() で設定する

    def _serve(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        res = self.stub({
            "rawPath": urlsplit(self.path).path,
            "headers": dict(self.headers),
            "body": base64.b64encode(body).decode(),
            "isBase64Encoded": True,
            "requestContext": {"requestId": str(uuid.uuid4()), "http": {"method": self.command}},
        })
        payload = res["body"].encode()
        self.send_response(res["statusCode"])
        for name, value in res["headers"].items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_DELETE = _serve

    def log_message(self, format: str, *args: object) -> None:
        pass  # the stub already logs one JSON line per request


def main() -> None:
    os.environ.setdefault("APP_ENV", "local")
    os.environ.setdefault("STUB_API_KEY", "local-stub-key")
    port = int(os.environ.get("PORT", "8090"))
    FunctionUrlAdapter.stub = Stub(load_api_key(os.environ))
    with ThreadingHTTPServer(("", port), FunctionUrlAdapter) as server:
        print(f"analyzer stub listening on :{port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
