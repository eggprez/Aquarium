use serde_json::Value;
use std::sync::OnceLock;

pub const CLIENT_NAME: &str = "Aquarium";
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

/// The `Authorization` value for an unauthenticated request — sign-in, and
/// anything else that runs before there is a token.
pub fn auth_header_anon(device_id: &str) -> String {
    format!(
        "MediaBrowser Client=\"{}\", Device=\"Linux\", DeviceId=\"{}\", Version=\"{}\"",
        CLIENT_NAME, device_id, CLIENT_VERSION
    )
}

pub fn auth_header(token: &str, device_id: &str) -> String {
    format!("{}, Token=\"{}\"", auth_header_anon(device_id), token)
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
        // The `MediaBrowser` scheme in the standard `Authorization` header is
        // the only carrier Jellyfin 12 reads by default; `X-Emby-Token` and
        // the other Emby-era headers are behind an admin opt-in there and
        // going away, so there is no point sending the token twice.
        .header("Authorization", auth_header(token, device_id))
        .json(body)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    Ok(resp.status())
}
