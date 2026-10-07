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

/// 1枚の画像の判定結果。size と sha256 は、API が画像を加工せずに送ったことを確かめるためのもの。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Analysis {
    pub valid: bool,
    pub reason: &'static str,
    pub size: usize,
    pub sha256: String,
}

/// 画像を判定する。スタブは解析せず、受け付けた画像をすべて valid とする。
pub fn analyze(image: &[u8]) -> Analysis {
    Analysis {
        valid: true,
        reason: "stub",
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
    fn every_image_is_valid_and_fingerprinted() {
        let image = [0xff, 0xd8, 0xff, 0xe0];
        assert_eq!(
            analyze(&image),
            Analysis {
                valid: true,
                reason: "stub",
                size: 4,
                sha256: hex::encode(Sha256::digest(image)),
            }
        );
    }

    #[test]
    fn only_the_same_api_key_matches() {
        let key = ApiKey::new("test-key");
        assert!(key.matches(b"test-key"));
        for given in ["", "nope", "test-key-longer", "TEST-KEY"] {
            assert!(!key.matches(given.as_bytes()), "{given}");
        }
    }
}
