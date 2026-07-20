use serde_json::Value;
use std::sync::OnceLock;

pub const CLIENT_NAME: &str = "FellyJin";
pub const CLIENT_VERSION: &str = env!("CARGO_PKG_VERSION");

static HTTP: OnceLock<reqwest::Client> = OnceLock::new();

pub fn http() -> &'static reqwest::Client {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(format!("{}/{}", CLIENT_NAME, CLIENT_VERSION))
            .connect_timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("failed to build http client")
    })
}

pub fn auth_header(token: &str, device_id: &str) -> String {
    format!(
        "MediaBrowser Client=\"{}\", Device=\"Linux\", DeviceId=\"{}\", Version=\"{}\", Token=\"{}\"",
        CLIENT_NAME, device_id, CLIENT_VERSION, token
    )
}

/// POST a JSON body to a Jellyfin endpoint. `path` must start with '/'.
pub async fn post(
    server: &str,
    token: &str,
    device_id: &str,
    path: &str,
    body: &Value,
) -> Result<reqwest::StatusCode, String> {
    let url = format!("{}{}", server.trim_end_matches('/'), path);
    let resp = http()
        .post(&url)
        .header("Authorization", auth_header(token, device_id))
        .header("X-Emby-Token", token)
        .json(body)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    Ok(resp.status())
}
