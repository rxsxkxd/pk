// Business rules of the stub (../DESIGN.md 3): who may ask (the shared API key) and how one image is
// judged. The stub does no analysis and accepts every image; the real analysis server's judgment would go
// here. Knows nothing about Lambda or HTTP. Same structure as ../python/analyzer.py.

import { createHash, timingSafeEqual } from 'node:crypto';

// 共有の API キー（3.3）。キーそのものではなく SHA-256 を持ち、定数時間で比べる（長さの違いでも時間が変わらないように）。
export class ApiKey {
  #digest;

  constructor(key) {
    this.#digest = sha256(key);
  }

  matches(given) {
    return timingSafeEqual(sha256(given), this.#digest);
  }
}

// 画像を判定する。スタブは解析せず、受け付けた画像をすべて valid とする。
// size と sha256 は、API が画像を加工せずに送ったことを確かめるためのもの。
export function analyze(image) {
  return { valid: true, reason: 'stub', size: image.length, sha256: createHash('sha256').update(image).digest('hex') };
}

function sha256(value) {
  return createHash('sha256').update(value).digest();
}
