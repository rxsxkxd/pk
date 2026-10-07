//! Same cases as the Node stub: ../testdata/cases.json.

use analyzer_stub::analyzer::{ApiKey, Auth};
use analyzer_stub::{AuthSetting, Stub, local_api_key};
use lambda_http::http::Request as HttpRequest;
use lambda_http::{Body, Request};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};

/// テスト用にログを溜めるスタブを作る。
/// The log lines a test stub wrote.
type Logs = Arc<Mutex<Vec<Map<String, Value>>>>;

fn stub() -> (Stub, Logs) {
    let logs = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&logs);
    (
        Stub::with_logger(
            Auth::ApiKey(ApiKey::new("test-key")),
            Box::new(move |line| sink.lock().unwrap().push(line)),
        ),
        logs,
    )
}

/// ケースの指定からリクエストを組み立てる（Lambda が base64 を戻したあとの Body::Binary）。
fn request(case: &Value, body: Vec<u8>) -> Request {
    let mut builder = HttpRequest::builder()
        .method(case["method"].as_str().unwrap_or("POST"))
        .uri(case["path"].as_str().unwrap_or("/v1/analyze"))
        .header(
            "content-type",
            case["contentType"].as_str().unwrap_or("application/octet-stream"),
        );
    match &case["apiKey"] {
        Value::Null if case.get("apiKey").is_some() => {}
        Value::String(key) => builder = builder.header("x-api-key", key),
        _ => builder = builder.header("x-api-key", "test-key"),
    }
    builder
        .body(if body.is_empty() {
            Body::Empty
        } else {
            Body::Binary(body)
        })
        .unwrap()
}

#[test]
fn shared_cases() {
    let file = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../testdata/cases.json")).unwrap();
    let cases: Value = serde_json::from_str(&file).unwrap();
    for case in cases["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let body = hex::decode(case["bodyHex"].as_str().unwrap()).unwrap();
        let (stub, logs) = stub();

        let res = stub.handle(&request(case, body.clone()));

        assert_eq!(res.status().as_u16() as u64, case["status"].as_u64().unwrap(), "{name}");
        let logs = logs.lock().unwrap();
        assert_eq!(logs.len(), 1, "{name}");
        if res.status() == 200 {
            let Body::Text(text) = res.body() else {
                panic!("{name}: body is not text")
            };
            let json: Value = serde_json::from_str(text).unwrap();
            assert_eq!(json["valid"], case["valid"], "{name}");
            // The log proves the bytes arrived unchanged: same length and SHA-256 as what was sent.
            assert_eq!(logs[0]["bytes"], json!(body.len()), "{name}");
            assert_eq!(logs[0]["sha256"], json!(hex::encode(Sha256::digest(&body))), "{name}");
        }
    }
}

#[test]
fn function_url_event_with_base64_body() {
    // A Function URL event as Lambda delivers it: the octet-stream body is base64 encoded.
    let image = [0xff_u8, 0xd8, 0xff, 0xe0, b'r', b'u', b's', b't'];
    let event = json!({
        "version": "2.0", "routeKey": "$default", "rawPath": "/v1/analyze", "rawQueryString": "",
        "headers": { "content-type": "application/octet-stream", "x-api-key": "test-key", "host": "x.lambda-url.ap-northeast-1.on.aws" },
        "requestContext": {
            "accountId": "anonymous", "apiId": "x", "domainName": "x.lambda-url.ap-northeast-1.on.aws", "domainPrefix": "x",
            "http": { "method": "POST", "path": "/v1/analyze", "protocol": "HTTP/1.1", "sourceIp": "127.0.0.1", "userAgent": "test" },
            "requestId": "req-1", "routeKey": "$default", "stage": "$default", "time": "05/Oct/2026:00:00:00 +0000", "timeEpoch": 0
        },
        "body": base64_encode(&image), "isBase64Encoded": true
    });
    let req = lambda_http::request::from_str(&event.to_string()).unwrap();
    let (stub, logs) = stub();

    let res = stub.handle(&req);

    assert_eq!(res.status(), 200);
    let logs = logs.lock().unwrap();
    assert_eq!(logs[0]["requestId"], "req-1");
    assert_eq!(logs[0]["sha256"], json!(hex::encode(Sha256::digest(image))));
}

#[test]
fn same_response_body_and_log_keys_as_node_and_python() {
    let case = json!({});
    let (stub, logs) = stub();

    let res = stub.handle(&request(&case, vec![0xff, 0xd8, 0xff]));

    let Body::Text(text) = res.body() else {
        panic!("body is not text")
    };
    assert_eq!(text, r#"{"valid":true,"reason":"stub"}"#);
    let logs = logs.lock().unwrap();
    let keys: Vec<&str> = logs[0].keys().map(String::as_str).collect();
    // No request context here, so requestId is omitted (as Node's JSON.stringify drops undefined).
    assert_eq!(keys, ["level", "msg", "status", "bytes", "sha256", "valid"]);
}

#[test]
fn api_key_comes_from_stub_api_key_only_when_app_env_is_local() {
    let env = |vars: &'static [(&'static str, &'static str)]| {
        move |name: &str| vars.iter().find(|(k, _)| *k == name).map(|(_, v)| v.to_string())
    };
    assert_eq!(
        local_api_key(env(&[("APP_ENV", "local"), ("STUB_API_KEY", "k")])),
        Some("k".into())
    );
    assert_eq!(local_api_key(env(&[("STUB_API_KEY", "k")])), None);
    assert_eq!(local_api_key(env(&[("APP_ENV", "local"), ("STUB_API_KEY", "")])), None);
}

/// テスト用の最小限の base64 エンコード（依存を増やさないため）。
fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    bytes
        .chunks(3)
        .flat_map(|c| {
            let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
            (0..4).map(move |i| {
                if i <= c.len() {
                    TABLE[(n >> (18 - 6 * i) & 63) as usize] as char
                } else {
                    '='
                }
            })
        })
        .collect()
}

#[test]
fn stub_auth_none_skips_the_api_key() {
    let stub = Stub::with_logger(Auth::None, Box::new(|_| {}));
    let res = stub.handle(&request(&json!({ "apiKey": null }), vec![0xff, 0xd8, 0xff]));
    assert_eq!(res.status(), 200);
}

#[test]
fn the_api_key_is_required_unless_none_is_explicit() {
    assert_eq!(AuthSetting::from_env_value(None), Ok(AuthSetting::ApiKey));
    assert_eq!(AuthSetting::from_env_value(Some("api-key")), Ok(AuthSetting::ApiKey));
    assert_eq!(AuthSetting::from_env_value(Some("none")), Ok(AuthSetting::None));
    assert!(
        AuthSetting::from_env_value(Some("off"))
            .unwrap_err()
            .contains("STUB_AUTH")
    );
}
