//! Image analysis server stub (Rust) for checking the ticket API on AWS Lambda. Runs behind a Lambda
//! Function URL. This crate parses and checks the request (route, Content-Type, body; see ../DESIGN.md 3)
//! and logs it; the API key rule and judging the image are the `analyzer` module. Same structure as
//! ../python/index.py and ../node/index.mjs; all are checked against ../testdata/cases.json.

pub mod analyzer;

use analyzer::{Auth, analyze};
use lambda_http::http::{Method, StatusCode, header::CONTENT_TYPE};
use lambda_http::request::RequestContext;
use lambda_http::{Body, Request, RequestExt, Response};
use serde_json::{Map, Value, json};
use std::str::FromStr;

/// Receives one log line (as JSON fields) per request.
pub type Logger = Box<dyn Fn(Map<String, Value>) + Send + Sync>;

/// スタブが見るリクエストの項目（Function URL のイベントから取り出したもの）。
#[derive(Debug)]
pub struct StubRequest<'a> {
    pub method: &'a Method,
    pub path: &'a str,
    pub api_key: &'a [u8],
    /// パラメーター（; 以降）を外し、小文字にしたもの
    pub content_type: String,
    /// octet-stream のボディは、Function URL が base64 で渡し、lambda_http が Body::Binary に戻す
    pub body: &'a [u8],
    pub request_id: Option<String>,
}

impl<'a> From<&'a Request> for StubRequest<'a> {
    fn from(req: &'a Request) -> Self {
        let header = |name| req.headers().get(name).map(|v| v.as_bytes()).unwrap_or_default();
        let content_type = String::from_utf8_lossy(header(CONTENT_TYPE.as_str()));
        Self {
            method: req.method(),
            path: req.uri().path(),
            api_key: header("x-api-key"),
            content_type: content_type
                .split(';')
                .next()
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase(),
            body: match req.body() {
                Body::Text(text) => text.as_bytes(),
                Body::Binary(bytes) => bytes,
                _ => &[],
            },
            request_id: match req.request_context_ref() {
                Some(RequestContext::ApiGatewayV2(ctx)) => ctx.request_id.clone(),
                _ => None,
            },
        }
    }
}

/// 応答（ステータスと本文）と、ログに足す項目。
#[derive(Debug)]
pub struct Outcome {
    pub status: StatusCode,
    pub body: Value,
    pub log_fields: Map<String, Value>,
}

impl Outcome {
    fn new(status: StatusCode, body: Value) -> Self {
        Self {
            status,
            body,
            log_fields: Map::new(),
        }
    }

    fn with_log(mut self, fields: Value) -> Self {
        if let Value::Object(fields) = fields {
            self.log_fields = fields;
        }
        self
    }
}

/// Lambda（Function URL）の応答にする。
fn json_response(status: StatusCode, body: &Value) -> Response<Body> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json")
        .body(Body::Text(body.to_string()))
        .expect("static response parts are valid")
}

/// Function URL のリクエストを確かめて応答を返す（ログの出力先はテスト用に差し替えられる）。
pub struct Stub {
    auth: Auth,
    log: Logger,
}

impl Stub {
    /// 認証の決まりから、標準出力に JSON ログを出すスタブを作る。
    pub fn new(auth: Auth) -> Self {
        Self::with_logger(auth, Box::new(print_log))
    }

    /// 認証の決まりとログの出力先からスタブを作る。
    pub fn with_logger(auth: Auth, log: Logger) -> Self {
        Self { auth, log }
    }

    /// リクエストを確かめ、1行のログを出して応答に変える。
    pub fn handle(&self, req: &Request) -> Response<Body> {
        let request = StubRequest::from(req);
        let Outcome {
            status,
            body,
            log_fields,
        } = self.check(&request);
        let mut line = Map::new();
        line.insert("level".into(), json!("INFO"));
        line.insert("msg".into(), json!("analyzed"));
        if let Some(id) = request.request_id {
            line.insert("requestId".into(), json!(id));
        }
        line.insert("status".into(), json!(status.as_u16()));
        line.extend(log_fields);
        (self.log)(line);
        json_response(status, &body)
    }

    /// 仕様（../DESIGN.md 3.2）の順にリクエストを確かめ、通ったものだけ画像の判定（analyzer）に渡す。
    /// API キーの照合も analyzer。
    pub fn check(&self, request: &StubRequest) -> Outcome {
        if request.method != Method::POST || request.path != "/v1/analyze" {
            return Outcome::new(StatusCode::NOT_FOUND, json!({ "error": "not found" }));
        }
        if !self.auth.allows(request.api_key) {
            return Outcome::new(StatusCode::UNAUTHORIZED, json!({ "error": "invalid api key" }));
        }
        if request.content_type != "application/octet-stream" {
            let error = json!({ "error": "Content-Type must be application/octet-stream" });
            return Outcome::new(StatusCode::BAD_REQUEST, error)
                .with_log(json!({ "contentType": request.content_type }));
        }
        if request.body.is_empty() {
            return Outcome::new(StatusCode::BAD_REQUEST, json!({ "error": "empty body" }));
        }

        let analysis = analyze(request.body);
        let result = analysis.result.as_str();
        let body = json!({
            "confidence": analysis.confidence,
            "detected": analysis.detected,
            "reason": analysis.reason,
            "result": result,
            "status": StatusCode::OK.as_u16(),
        });
        Outcome::new(StatusCode::OK, body)
            .with_log(json!({ "bytes": analysis.size, "sha256": analysis.sha256, "result": result }))
    }
}

/// STUB_AUTH の値。API キーの読み込み（非同期）の前に、どちらの決まりにするかを決める。
#[derive(Debug, PartialEq, Eq)]
pub enum AuthSetting {
    /// API キーを確かめる（既定。設定漏れで、公開した Function URL のスタブが誰でも呼べる状態にならないように）
    ApiKey,
    /// 確かめない。STUB_AUTH=none を明示したときだけ（VPC 内で SG だけで許可する場合）
    None,
}

impl FromStr for AuthSetting {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "api-key" => Ok(Self::ApiKey),
            "none" => Ok(Self::None),
            other => Err(format!("STUB_AUTH must be api-key or none, got {other:?}")),
        }
    }
}

impl AuthSetting {
    /// STUB_AUTH の値（未設定なら api-key）から決める。
    pub fn from_env_value(value: Option<&str>) -> Result<Self, String> {
        value.unwrap_or("api-key").parse()
    }
}

/// API キーを確かめない設定で起動したことを、ログに1行出す（気づけるように）。
pub fn warn_auth_disabled() {
    let mut line = Map::new();
    line.insert("level".into(), json!("WARN"));
    line.insert("msg".into(), json!("api key check is disabled (STUB_AUTH=none)"));
    print_log(line);
}

/// ローカル実行用の API キーを返す（APP_ENV=local のときだけ STUB_API_KEY の平文を使う）。
pub fn local_api_key(env: impl Fn(&str) -> Option<String>) -> Option<String> {
    (env("APP_ENV").as_deref() == Some("local"))
        .then(|| env("STUB_API_KEY"))
        .flatten()
        .filter(|k| !k.is_empty())
}

/// 1行の JSON ログを出す（画像の中身は出さない）。
fn print_log(fields: Map<String, Value>) {
    let mut line = Map::new();
    let time = humantime::format_rfc3339_millis(std::time::SystemTime::now()).to_string();
    line.insert("time".into(), json!(time));
    line.extend(fields);
    println!("{}", Value::Object(line));
}
