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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{FakeServer, Resp};
    use serde_json::json;

    #[test]
    fn the_client_introduces_itself() {
        assert_eq!(CLIENT_NAME, "Aquarium");
        assert!(!CLIENT_VERSION.is_empty());
        assert_eq!(
            auth_header_anon("dev-1"),
            format!("MediaBrowser Client=\"Aquarium\", Device=\"Linux\", DeviceId=\"dev-1\", Version=\"{CLIENT_VERSION}\"")
        );
        assert_eq!(
            auth_header("tok", "dev-1"),
            format!("{}, Token=\"tok\"", auth_header_anon("dev-1"))
        );
    }

    #[test]
    fn there_is_one_shared_client() {
        assert!(std::ptr::eq(http(), http()));
    }

    #[tokio::test]
    async fn post_sends_json_with_the_token_in_authorization_only() {
        let server = FakeServer::start(|_| Resp::status(204));
        // A trailing slash on the server is not doubled.
        let status = post(&format!("{}/", server.url), "tok", "dev-1", "/Sessions/Playing", &json!({ "ItemId": "i" }))
            .await
            .unwrap();
        assert_eq!(status.as_u16(), 204);
        let reqs = server.requests();
        assert_eq!(reqs.len(), 1);
        let r = &reqs[0];
        assert_eq!(r.method, "POST");
        assert_eq!(r.target, "/Sessions/Playing");
        assert_eq!(r.json(), json!({ "ItemId": "i" }));
        assert_eq!(r.header("authorization"), Some(auth_header("tok", "dev-1").as_str()));
        assert!(r.header("content-type").unwrap_or("").starts_with("application/json"));
        assert_eq!(r.header("user-agent"), Some(format!("Aquarium/{CLIENT_VERSION}").as_str()));
        // Jellyfin 12 ignores the legacy header; it must not be sent at all.
        assert_eq!(r.header("x-emby-token"), None);
        assert_eq!(r.header("x-emby-authorization"), None);
    }

    #[tokio::test]
    async fn post_reports_the_status_and_fails_only_without_an_answer() {
        let server = FakeServer::start(|_| Resp::status(500));
        assert_eq!(post(&server.url, "t", "d", "/x", &json!({})).await.unwrap().as_u16(), 500);
        assert!(post(&FakeServer::dead_url(), "t", "d", "/x", &json!({})).await.is_err());
    }
}
