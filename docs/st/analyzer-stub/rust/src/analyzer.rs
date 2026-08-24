//! Business rules of the stub (../DESIGN.md 3): who may ask (the shared API key) and how one image is
//! judged. The stub does no analysis and accepts every image; the real analysis server's judgment would go
//! here. Knows nothing about Lambda or HTTP. Same structure as ../python/analyzer.py and ../node/analyzer.mjs.

use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

/// 共有の API キー（3.3）。キーそのものではなく SHA-256 を持ち、定数時間で比べる（長さの違いでも時間が変わらないように）。
pub struct ApiKey {
    digest: [u8; 32],
}

impl ApiKey {
    pub fn new(key: &str) -> Self {
        Self {
            digest: sha256(key.as_bytes()),
        }
    }

    pub fn matches(&self, given: &[u8]) -> bool {
        sha256(given).ct_eq(&self.digest).into()
    }
}

/// 認証の決まり。API キーを確かめるか、確かめないか（STUB_AUTH=none。VPC 内で、SG で許可した送信元からだけ
/// 届く場合に使う）。
pub enum Auth {
    ApiKey(ApiKey),
    None,
}

impl Auth {
    pub fn allows(&self, given: &[u8]) -> bool {
        match self {
            Auth::ApiKey(key) => key.matches(given),
            Auth::None => true,
        }
    }
}

/// 判定の結果（本物の解析サーバーの応答の `result`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Judgment {
    Pass,
    Reject,
    Retry,
}

impl Judgment {
    /// 応答に書く値（`PASS` / `REJECT` / `RETRY`）。
    pub fn as_str(self) -> &'static str {
        match self {
            Judgment::Pass => "PASS",
            Judgment::Reject => "REJECT",
            Judgment::Retry => "RETRY",
        }
    }
}

/// 1枚の画像の判定結果（本物の解析サーバーの応答の項目: result・confidence・detected・reason）。
/// size と sha256 は、API が画像を加工せずに送ったことを確かめるためのもの（応答には入れず、ログに出す）。
#[derive(Debug, Clone, PartialEq)]
pub struct Analysis {
    pub result: Judgment,
    pub confidence: f64,
    pub detected: &'static str,
    pub reason: &'static str,
    pub size: usize,
    pub sha256: String,
}

/// 画像を判定する。スタブは解析せず、受け付けた画像をすべて PASS とする。
pub fn analyze(image: &[u8]) -> Analysis {
    Analysis {
        result: Judgment::Pass,
        confidence: 1.0,
        detected: "stub",
        reason: "stub: no analysis",
        size: image.len(),
        sha256: hex::encode(sha256(image)),
    }
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_image_passes_and_is_fingerprinted() {
        let image = [0xff, 0xd8, 0xff, 0xe0];
        assert_eq!(
            analyze(&image),
            Analysis {
                result: Judgment::Pass,
                confidence: 1.0,
                detected: "stub",
                reason: "stub: no analysis",
                size: 4,
                sha256: hex::encode(Sha256::digest(image)),
            }
        );
        assert_eq!(Judgment::Pass.as_str(), "PASS");
    }

    #[test]
    fn only_the_same_api_key_matches() {
        let key = ApiKey::new("test-key");
        assert!(key.matches(b"test-key"));
        for given in ["", "nope", "test-key-longer", "TEST-KEY"] {
            assert!(!key.matches(given.as_bytes()), "{given}");
        }
    }

    #[test]
    fn auth_none_lets_everything_through() {
        assert!(Auth::None.allows(b""));
        assert!(!Auth::ApiKey(ApiKey::new("test-key")).allows(b""));
    }
}
