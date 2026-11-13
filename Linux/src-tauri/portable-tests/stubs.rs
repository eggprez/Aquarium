//! Stand-ins for the two D-Bus modules, for hosts with no libdbus (macOS).
//! On Linux the real `secret.rs` and `idle.rs` are built instead and these are
//! not compiled.
//!
//! `secret` here is an in-memory keyring with the real module's public
//! surface, so `server.rs` and `downloads.rs` can be exercised end to end. It
//! is a test double: nothing about the real Secret Service path (caching, the
//! legacy adoption, the config.json fallback) is covered by it. Those tests
//! are in `secret.rs` itself and run on Linux.

pub mod secret {
    use serde_json::{json, Value};
    use std::collections::HashMap;
    use std::sync::Mutex;

    static STORE: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);
    const ACCOUNT: &str = "jellyfin-access-token";
    const PENDING: &str = "jellyfin-pending-revocation";

    fn with<R>(f: impl FnOnce(&mut HashMap<String, String>) -> R) -> R {
        let mut g = STORE.lock().unwrap_or_else(|e| e.into_inner());
        f(g.get_or_insert_with(HashMap::new))
    }

    /// Test hook: empty the keyring.
    pub fn reset_for_tests() {
        with(|m| m.clear());
    }

    pub fn hydrate(mut cfg: Value) -> Value {
        if let Some(obj) = cfg.as_object_mut() {
            obj.remove("token");
        }
        cfg["has_token"] = json!(token().is_some());
        cfg["token_storage"] = json!(backend_name());
        if let Some(list) = cfg.get_mut("accounts").and_then(|v| v.as_array_mut()) {
            for a in list {
                if let Some(obj) = a.as_object_mut() {
                    obj.remove("token");
                }
            }
        }
        cfg
    }

    pub fn dehydrate(mut cfg: Value) -> Value {
        if let Some(obj) = cfg.as_object_mut() {
            for k in ["token", "token_storage", "has_token", "accounts", "known_servers"] {
                obj.remove(k);
            }
        }
        cfg
    }

    pub fn token() -> Option<String> {
        with(|m| m.get(ACCOUNT).cloned())
    }

    pub fn store(tok: &str) -> Result<(), String> {
        with(|m| m.insert(ACCOUNT.into(), tok.into()));
        Ok(())
    }

    pub fn clear() {
        with(|m| m.remove(ACCOUNT));
    }

    pub fn park_pending_revocation(token: &str, server: &str, device_id: &str) -> Result<(), String> {
        let blob = json!({ "token": token, "server": server, "device_id": device_id });
        with(|m| m.insert(PENDING.into(), blob.to_string()));
        Ok(())
    }

    pub fn pending_revocation() -> Option<Value> {
        with(|m| m.get(PENDING).and_then(|s| serde_json::from_str(s).ok()))
    }

    pub fn clear_pending_revocation() {
        with(|m| m.remove(PENDING));
    }

    pub fn backend_name() -> &'static str {
        "keyring"
    }

    pub fn store_account(key: &str, tok: &str) -> Result<(), String> {
        with(|m| m.insert(format!("{ACCOUNT}:{key}"), tok.into()));
        Ok(())
    }

    pub fn account_token(key: &str) -> Option<String> {
        with(|m| m.get(&format!("{ACCOUNT}:{key}")).cloned())
    }

    pub fn clear_account(key: &str) {
        with(|m| m.remove(&format!("{ACCOUNT}:{key}")));
    }
}

pub mod idle {
    /// There is no session bus to ask, so taking the lock always fails, which
    /// is what the real one does on a machine with no D-Bus.
    pub struct IdleInhibitor;

    impl IdleInhibitor {
        pub fn new() -> Result<Self, String> {
            Err("no D-Bus on this host".into())
        }
    }

    pub enum SuspendInhibitor {
        None,
    }

    impl SuspendInhibitor {
        pub fn new(_why: &str) -> Result<Self, String> {
            Err("no D-Bus on this host".into())
        }
    }
}
