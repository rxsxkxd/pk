//! Lambda entry point (provided.al2023 `bootstrap`): loads the API key once, then serves Function URL
//! requests with analyzer_stub::Stub.

use analyzer_stub::{Stub, local_api_key};
use lambda_http::{Error, Request, run, service_fn};
use std::{env, sync::Arc};

#[tokio::main]
async fn main() -> Result<(), Error> {
    let stub = Arc::new(Stub::new(&load_api_key().await?));
    run(service_fn(move |req: Request| {
        let stub = Arc::clone(&stub);
        async move { Ok::<_, Error>(stub.handle(&req)) }
    }))
    .await
}

/// Parameter Store の SecureString から API キーを読み込む（APP_ENV=local のときだけ STUB_API_KEY の平文を使う）。
async fn load_api_key() -> Result<String, Error> {
    if let Ok(name) = env::var("API_KEY_PARAMETER_NAME") {
        let config = aws_config::load_from_env().await;
        let out = aws_sdk_ssm::Client::new(&config)
            .get_parameter()
            .name(&name)
            .with_decryption(true)
            .send()
            .await?;
        return out
            .parameter()
            .and_then(|p| p.value())
            .filter(|v| !v.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| format!("parameter {name} is empty").into());
    }
    local_api_key(|name| env::var(name).ok()).ok_or_else(|| "API_KEY_PARAMETER_NAME is not set".into())
}
