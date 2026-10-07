//! Local server for the stub (not deployed): converts HTTP requests into Lambda Function URL requests and
//! serves them with analyzer_stub::Stub. Same role as ../node/local.mjs and ../python/local.py.
//! Run: ./build.sh dev  ->  POST http://localhost:8090/v1/analyze  (x-api-key: local-stub-key)

use analyzer_stub::{Stub, local_api_key};
use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use lambda_http::aws_lambda_events::apigw::ApiGatewayV2httpRequestContext;
use lambda_http::request::RequestContext;
use lambda_http::{Body, RequestExt};
use std::env;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::net::TcpListener;

type Error = Box<dyn std::error::Error + Send + Sync>;

#[tokio::main]
async fn main() -> Result<(), Error> {
    // Same defaults as local.mjs / local.py: a plain-text key, allowed only with APP_ENV=local.
    let var = |name: &str, default: &str| env::var(name).unwrap_or_else(|_| default.into());
    let port: u16 = var("PORT", "8090").parse()?;
    let key = local_api_key(|name| match name {
        "APP_ENV" => Some(var("APP_ENV", "local")),
        "STUB_API_KEY" => Some(var("STUB_API_KEY", "local-stub-key")),
        _ => env::var(name).ok(),
    })
    .ok_or("STUB_API_KEY must be set with APP_ENV=local")?;

    let stub = Arc::new(Stub::new(&key));
    let next_id = Arc::new(AtomicU64::new(1));
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    println!("analyzer stub listening on :{port}");

    loop {
        let (stream, _) = listener.accept().await?;
        let (stub, next_id) = (Arc::clone(&stub), Arc::clone(&next_id));
        tokio::spawn(async move {
            let service = service_fn(move |req| {
                let request_id = format!("local-{}", next_id.fetch_add(1, Ordering::Relaxed));
                serve(Arc::clone(&stub), req, request_id)
            });
            if let Err(err) = http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .await
            {
                eprintln!("connection error: {err}");
            }
        });
    }
}

/// HTTP のリクエストを Function URL と同じ形（ボディはバイト列、requestContext に requestId）にしてスタブに渡す。
async fn serve(
    stub: Arc<Stub>,
    req: hyper::Request<Incoming>,
    request_id: String,
) -> Result<hyper::Response<Full<Bytes>>, hyper::Error> {
    let (parts, body) = req.into_parts();
    let bytes = body.collect().await?.to_bytes();
    let body = if bytes.is_empty() {
        Body::Empty
    } else {
        Body::Binary(bytes.to_vec())
    };
    let mut context = ApiGatewayV2httpRequestContext::default(); // #[non_exhaustive]: set fields after default()
    context.request_id = Some(request_id);
    let request =
        lambda_http::Request::from_parts(parts, body).with_request_context(RequestContext::ApiGatewayV2(context));

    let (parts, body) = stub.handle(&request).into_parts();
    Ok(hyper::Response::from_parts(
        parts,
        Full::new(Bytes::copy_from_slice(body.as_ref())),
    ))
}
