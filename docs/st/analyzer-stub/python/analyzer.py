"""Business rules of the stub (../DESIGN.md 3): who may ask (the shared API key) and how one image is
judged. The stub does no analysis and accepts every image; the real analysis server's judgment would go
here. Knows nothing about Lambda or HTTP."""

import hashlib
import hmac
from dataclasses import dataclass


class ApiKey:
    """共有の API キー（3.3）。キーそのものではなく SHA-256 を持ち、定数時間で比べる（長さの違いでも時間が変わらないように）。"""

    def __init__(self, key: str) -> None:
        self._digest = _sha256(key.encode())

    def matches(self, given: str) -> bool:
        return hmac.compare_digest(_sha256(given.encode()), self._digest)


class NoApiKey:
    """API キーを確かめない決まり（STUB_AUTH=none）。VPC 内で、SG で許可した送信元からだけ届く場合に使う。"""

    def matches(self, given: str) -> bool:
        return True


type Auth = ApiKey | NoApiKey


@dataclass(frozen=True)
class Analysis:
    """1枚の画像の判定結果。size と sha256 は、API が画像を加工せずに送ったことを確かめるためのもの。"""

    valid: bool
    reason: str
    size: int
    sha256: str


def analyze(image: bytes) -> Analysis:
    """画像を判定する。スタブは解析せず、受け付けた画像をすべて valid とする。"""
    return Analysis(valid=True, reason="stub", size=len(image), sha256=hashlib.sha256(image).hexdigest())


def _sha256(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()
