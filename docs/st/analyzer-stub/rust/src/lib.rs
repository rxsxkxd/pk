//! Image analysis server stub (Rust) for checking the ticket API on AWS Lambda. Runs behind a Lambda
//! Function URL. It does no analysis: every accepted image is valid. Same behavior as the Node stub
//! (../node/index.mjs); both are checked against ../testdata/cases.json.

use lambda_http::http::{Method, StatusCode, header::CONTENT_TYPE};
use lambda_http::request::RequestContext;
use lambda_http::{Body, Request, RequestExt, Response};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

/// Receives one log line (as JSON fields) per request.
pub type Logger = Box<dyn Fn(Value) + Send + Sync>;

pub struct Stub {
    key_digest: [u8; 32],
    log: Logger,
}

impl Stub {
    /// API キーから、標準出力に JSON ログを出すスタブを作る。
    pub fn new(api_key: &str) -> Self {
        Self::with_logger(api_key, Box::new(print_log))
    }

    /// API キーとログの出力先からスタブを作る（テスト用にログを差し替えられる）。
    pub fn with_logger(api_key: &str, log: Logger) -> Self {
        Self {
            key_digest: digest(api_key.as_bytes()),
            log,
        }
    }

    /// リクエストを検証し、受け付けた画像には解析せずに valid を返す。
    pub fn handle(&self, req: &Request) -> Response<Body> {
        let request_id = match req.request_context_ref() {
            Some(RequestContext::ApiGatewayV2(ctx)) => ctx.request_id.clone(),
            _ => None,
        };
        let reply = |status: StatusCode, body: Value, fields: Value| {
            let mut line =
                json!({ "level": "INFO", "msg": "analyzed", "requestId": request_id, "status": status.as_u16() });
            if let (Some(line), Value::Object(fields)) = (line.as_object_mut(), fields) {
                line.extend(fields);
            }
            (self.log)(line);
            Response::builder()
                .status(status)
                .header(CONTENT_TYPE, "application/json")
                .body(Body::Text(body.to_string()))
                .expect("static response parts are valid")
        };

        if req.method() != Method::POST || req.uri().path() != "/v1/analyze" {
            return reply(StatusCode::NOT_FOUND, json!({ "error": "not found" }), json!({}));
        }
        let given_key = req.headers().get("x-api-key").map(|v| v.as_bytes()).unwrap_or_default();
        if !bool::from(digest(given_key).ct_eq(&self.key_digest)) {
            return reply(
                StatusCode::UNAUTHORIZED,
                json!({ "error": "invalid api key" }),
                json!({}),
            );
        }

        let content_type = req
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .split(';')
            .next()
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if content_type != "application/octet-stream" {
            let body = json!({ "error": "Content-Type must be application/octet-stream" });
            return reply(StatusCode::BAD_REQUEST, body, json!({ "contentType": content_type }));
        }
        let image: &[u8] = match req.body() {
            Body::Empty => &[],
            Body::Text(text) => text.as_bytes(),
            Body::Binary(bytes) => bytes,
            _ => &[],
        };
        if image.is_empty() {
            return reply(StatusCode::BAD_REQUEST, json!({ "error": "empty body" }), json!({}));
        }

        // No analysis. bytes and sha256 let us check that the API forwarded the upload unchanged.
        let fields = json!({ "bytes": image.len(), "sha256": hex::encode(digest(image)), "valid": true });
        reply(StatusCode::OK, json!({ "valid": true, "reason": "stub" }), fields)
    }
}

/// ローカル実行用の API キーを返す（APP_ENV=local のときだけ STUB_API_KEY の平文を使う）。
pub fn local_api_key(env: impl Fn(&str) -> Option<String>) -> Option<String> {
    (env("APP_ENV").as_deref() == Some("local"))
        .then(|| env("STUB_API_KEY"))
        .flatten()
        .filter(|k| !k.is_empty())
}

/// 値を比較用の固定長の値（SHA-256）にする（長さの違いで比較時間が変わらないように）。
fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

/// 1行の JSON ログを出す（画像の中身は出さない）。
fn print_log(mut fields: Value) {
    if let Some(obj) = fields.as_object_mut() {
        obj.insert(
            "time".into(),
            json!(humantime::format_rfc3339_millis(std::time::SystemTime::now()).to_string()),
        );
    }
    println!("{fields}");
}
