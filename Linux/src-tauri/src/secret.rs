//! Where the Jellyfin access token lives.
//!
//! It used to be written straight into `~/.config/aquarium/config.json`, which
//! means any process running as the user — and any backup that sweeps up dotfiles
//! — walks away with a credential that grants full access to the media server.
//! The token now goes to the desktop keyring (Secret Service: gnome-keyring,
//! KWallet, …) and never touches the config file.
//!
//! The keyring is not guaranteed to be there, though: a headless session, a
//! locked keyring, or a desktop without a Secret Service provider all fail the
//! same way. Rather than lock the user out of their own client, those cases fall
//! back to the old file storage and say so in Settings — degraded, but honest.
//!
//! The token also never crosses the IPC boundary into the webview any more.
//! Everything that authenticates to Jellyfin (API calls, mpv, the downloader,
//! progress sync) now reads it from here on the Rust side, so a script running
//! in the webview has nothing to steal — see `server.rs`.
//!
//! Which is why the token is read once and kept in memory (`STATE`). Every
//! Jellyfin request needs it, and the first screen after sign-in fires a dozen
//! of them at once; without the cache each one was its own Secret Service
//! lookup. Against a locked keyring that is one unlock prompt *per in-flight
//! request* — the user gets asked for their password over and over. The same
//! lock serialises the misses, so even the first burst can only ever raise a
//! single prompt.
//!
//! All of it goes over a single long-lived D-Bus connection (`CONN`), which is
//! not just an optimisation: opening one per operation crash-looped
//! gnome-keyring and left the login keyring locked for the whole session. See
//! the note on `CONN` before changing how connections are managed here.

use dbus_secret_service::{Collection, EncryptionType, Error as SsError, SecretService};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

const SERVICE: &str = "dev.aquarium.app";
/// The service the token was filed under before the app was renamed from
/// FellyJin. Read once as a fallback and moved to `SERVICE` — see `adopt_legacy`.
const LEGACY_SERVICE: &str = "dev.fellyjin.app";
const ACCOUNT: &str = "jellyfin-access-token";
/// A token whose sign-out couldn't reach the server yet. Parked here so the
/// revocation can be retried instead of silently leaving a live session behind.
const PENDING_ACCOUNT: &str = "jellyfin-pending-revocation";
/// A Jellyfin account's session on a Seerr server (see `seerr.rs`), one item
/// per account: `seerr-session:<account key>`.
const SEERR_ACCOUNT: &str = "seerr-session";
/// The Secret Service alias for the collection we store in — on GNOME that
/// resolves to the user's login keyring.
const TARGET: &str = "default";
/// Stamped on every item we create. Kept at the value the `keyring` crate used
/// so items written before this module dropped that dependency still match.
const APPLICATION: &str = "rust-keyring";

/// What we already know, so we don't ask the keyring twice.
struct State {
    /// `None` = never looked. `Some(None)` = looked, and there is nothing to
    /// have — either no entry or no usable keyring, which the caller can't act
    /// differently on anyway.
    token: Option<Option<String>>,
    /// Which storage the last lookup proved was in play, for Settings.
    backend: Option<&'static str>,
    /// A parked revocation, the same way `token` is: `None` = never looked,
    /// `Some(None)` = nothing parked (or the keyring wouldn't say). Settings
    /// asks through `app_info` every time the sidebar footer redraws, and
    /// without this each of those was another keyring read, and another
    /// unlock prompt while the keyring was locked.
    pending: Option<Option<Value>>,
    /// Seerr sessions already looked up, by account key, misses and failed
    /// lookups included: every Seerr request reads its session from here.
    seerr: Vec<(String, Option<String>)>,
}

/// Held across the blocking Secret Service call on purpose: a second caller
/// that arrives mid-unlock waits and then reads the answer out of the cache,
/// instead of opening its own connection and queueing a second password
/// prompt behind the first.
static STATE: Mutex<State> = Mutex::new(State {
    token: None,
    backend: None,
    pending: None,
    seerr: Vec::new(),
});

/// Test hook: forget everything cached about the keyring.
#[cfg(test)]
pub fn reset_for_tests() {
    let mut s = STATE.lock().unwrap_or_else(|p| p.into_inner());
    s.token = None;
    s.backend = None;
    s.pending = None;
    s.seerr.clear();
}

/// A poisoned lock here means some earlier caller panicked mid-lookup. The
/// cache is still coherent — worst case a field is unset and gets refilled —
/// so recover rather than take the whole app down over it.
fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|p| p.into_inner())
}

/// The attribute set that identifies one of our items.
///
/// These four keys and their exact values are what the `keyring` crate wrote
/// while this module still used it. gnome-keyring matches items by their whole
/// attribute set, so changing any of them would orphan the token already in the
/// user's keyring and silently sign them out. Leave them alone.
fn attrs(account: &str) -> HashMap<&str, &str> {
    HashMap::from([
        ("service", SERVICE),
        ("username", account),
        ("target", TARGET),
        ("application", APPLICATION),
    ])
}

/// What we search on — deliberately narrower than what we write. `keyring`
/// searched the default collection on service and username alone, so an item
/// written before the `target` attribute existed still turns up.
fn search_attrs(account: &str) -> HashMap<&str, &str> {
    search_attrs_in(SERVICE, account)
}

fn search_attrs_in<'a>(service: &'a str, account: &'a str) -> HashMap<&'a str, &'a str> {
    HashMap::from([("service", service), ("username", account)])
}

fn label(account: &str) -> String {
    format!("{account}@{SERVICE}:{TARGET}")
}

/// The one Secret Service connection this process opens.
///
/// This is the entire reason the `keyring` crate is gone. It called
/// `SecretService::connect` *inside* every get/set/delete, so each operation
/// opened a fresh D-Bus connection, negotiated a DH session, and tore the
/// connection straight back down. gnome-keyring registers its per-connection
/// client record asynchronously, and a connection that closes inside that
/// window leaves the record NULL: the daemon hits
/// `gkd_secret_service_get_pkcs11_session: assertion 'client' failed`, a
/// property getter then returns NULL without setting a GError, and GLib-GIO
/// aborts the whole daemon.
///
/// The blast radius is not ours. systemd restarts the daemon, but the login
/// keyring is only auto-unlocked by PAM *at login*, so it comes back locked —
/// which takes out GNOME Online Accounts and anything else holding secrets
/// there, for the rest of the session.
///
/// One connection, opened on first use and held for the life of the process,
/// closes that window: the only teardown is at exit, with nothing in flight.
static CONN: Mutex<Option<SecretService>> = Mutex::new(None);

fn conn() -> MutexGuard<'static, Option<SecretService>> {
    CONN.lock().unwrap_or_else(|p| p.into_inner())
}

/// Run `op` against the default collection over the shared connection.
///
/// The handle can still go stale — something else on the system may restart
/// gnome-keyring — so a D-Bus-level failure discards it and retries once on a
/// fresh connection. Every other error (locked collection, dismissed prompt,
/// no such item) is a real answer about the keyring's state, not a transport
/// problem, and goes straight back to the caller.
fn with_collection<T>(op: impl Fn(&Collection<'_>) -> Result<T, SsError>) -> Result<T, SsError> {
    let mut slot = conn();
    let mut stale: Option<SsError> = None;
    for attempt in 0..2 {
        if slot.is_none() {
            *slot = Some(SecretService::connect(EncryptionType::Dh)?);
        }
        let outcome = {
            let ss = slot.as_ref().expect("connected just above");
            ss.get_default_collection().and_then(|c| {
                c.ensure_unlocked()?;
                op(&c)
            })
        };
        match outcome {
            Err(SsError::Dbus(e)) if attempt == 0 => {
                *slot = None;
                stale = Some(SsError::Dbus(e));
            }
            settled => return settled,
        }
    }
    Err(stale.expect("the loop only falls through after a D-Bus failure"))
}

/// A lookup that keeps the distinction the callers below need: "nothing
/// stored" and "the keyring wouldn't answer" are different facts, even though
/// most callers end up treating both as "no token".
fn read(account: &str) -> Result<Option<String>, String> {
    read_in(SERVICE, account)
}

fn read_in(service: &str, account: &str) -> Result<Option<String>, String> {
    let raw = with_collection(|c| match c.search_items(search_attrs_in(service, account))?.first() {
        // More than one match only happens if something else wrote an item
        // under our service and username; the first is as good as any.
        Some(item) => item.get_secret().map(Some),
        None => Ok(None),
    })
    .map_err(|e| e.to_string())?;

    match raw {
        None => Ok(None),
        Some(bytes) => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| "stored secret is not valid UTF-8".to_string()),
    }
}

fn write(account: &str, value: &str) -> Result<(), String> {
    with_collection(|c| {
        // Overwrite in place when the item is already there, and only create
        // one when it isn't. `create_item`'s `replace` flag matches on the
        // attribute set, but gnome-keyring stamps an `xdg:schema` attribute of
        // its own onto items it stores — so leaning on `replace` alone risks
        // filing a second, competing token beside the real one rather than
        // replacing it, and then `read` gets to pick between them.
        if let Some(item) = c.search_items(search_attrs(account))?.first() {
            return item.set_secret(value.as_bytes(), "text/plain");
        }
        c.create_item(
            &label(account),
            attrs(account),
            value.as_bytes(),
            true,
            "text/plain",
        )
        .map(|_| ())
    })
    .map_err(|e| e.to_string())
}

/// Deleting nothing is success — the caller wanted the secret gone, and it is.
fn wipe(account: &str) -> Result<(), String> {
    wipe_in(SERVICE, account)
}

fn wipe_in(service: &str, account: &str) -> Result<(), String> {
    with_collection(|c| {
        for item in c.search_items(search_attrs_in(service, account))? {
            item.delete()?;
        }
        Ok(())
    })
    .map_err(|e| e.to_string())
}

/// The token, from the cache if we've already been told, from the keyring at
/// most once otherwise. Caller holds the lock.
///
/// A failed lookup is remembered too. That costs something — unlock the
/// keyring by hand after cancelling the prompt and this process won't notice
/// until it restarts — but the alternative is re-prompting on every single
/// request for the rest of the session, which is what made this cache
/// necessary in the first place.
fn cached_token(st: &mut State) -> Option<String> {
    if let Some(known) = &st.token {
        return known.clone();
    }
    let found = match read(ACCOUNT) {
        Ok(None) => {
            st.backend = Some("keyring");
            adopt_legacy(ACCOUNT)
        }
        Ok(v) => {
            st.backend = Some("keyring");
            v
        }
        Err(e) => {
            crate::debug_log_line(&format!("secret: keyring read failed: {}", e));
            st.backend = Some("file");
            None
        }
    };
    st.token = Some(found.clone());
    found
}

/// Move an item filed under the pre-rename service name across to `SERVICE`,
/// so upgrading from FellyJin doesn't sign the user out. The old copy is only
/// removed once the new one is written.
fn adopt_legacy(account: &str) -> Option<String> {
    let value = read_in(LEGACY_SERVICE, account).ok().flatten()?;
    if write(account, &value).is_ok() {
        let _ = wipe_in(LEGACY_SERVICE, account);
        crate::debug_log_line("secret: moved token from the FellyJin keyring entry");
    }
    Some(value)
}

/// Read the token from the keyring. `None` covers both "nothing stored" and
/// "no keyring available" — the caller can't act differently on the two.
fn keyring_get() -> Option<String> {
    cached_token(&mut state())
}

fn keyring_set(token: &str) -> Result<(), String> {
    let mut st = state();
    let stored = write(ACCOUNT, token);
    // A write is as good a probe as a read, and a successful one re-arms a
    // cache that an earlier failed lookup had given up on.
    match &stored {
        Ok(()) => {
            st.token = Some(Some(token.to_owned()));
            st.backend = Some("keyring");
        }
        Err(_) => st.backend = Some("file"),
    }
    stored
}

fn keyring_clear() -> Result<(), String> {
    let mut st = state();
    st.token = Some(None);
    wipe(ACCOUNT)
}

/// Config as the frontend sees it. The token is *not* spliced back in: the
/// webview is told only whether a session exists (`has_token`), because a token
/// sitting in a JS variable is one XSS away from being exfiltrated.
///
/// A token still sitting in the config file is migrated on sight — that's the
/// upgrade path from a build that stored it in plaintext, and it's also what
/// erases the old copy from disk.
pub fn hydrate(mut cfg: Value) -> Value {
    let in_file = cfg
        .get("token")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_owned);

    if let Some(tok) = in_file {
        match keyring_set(&tok) {
            Ok(()) => {
                crate::debug_log_line("secret: migrated token from config.json to the keyring");
                // Only drop the plaintext copy once the keyring has it.
                if let Some(obj) = cfg.as_object_mut() {
                    obj.remove("token");
                }
                let _ = crate::config::save(&cfg);
                cfg["token_storage"] = json!("keyring");
            }
            Err(e) => {
                crate::debug_log_line(&format!(
                    "secret: keyring unavailable ({}) — token stays in config.json",
                    e
                ));
                cfg["token_storage"] = json!("file");
            }
        }
        if let Some(obj) = cfg.as_object_mut() {
            obj.remove("token");
        }
        cfg["has_token"] = json!(true);
        redact_accounts(&mut cfg);
        return cfg;
    }

    cfg["has_token"] = json!(keyring_get().is_some());
    cfg["token_storage"] = json!(backend_name());
    redact_accounts(&mut cfg);
    cfg
}

/// Strip anything credential-shaped out of a config the frontend wants saved.
///
/// Note what this deliberately no longer does: an absent token used to mean
/// "sign out" and cleared the keyring. Now that the frontend never holds the
/// token, *every* save arrives without one — treating that as a sign-out would
/// wipe the session the moment the user changed an unrelated setting. Clearing
/// is now explicit, via `server::logout`.
pub fn dehydrate(mut cfg: Value) -> Value {
    if let Some(obj) = cfg.as_object_mut() {
        obj.remove("token");
        obj.remove("token_storage");
        obj.remove("has_token");
        // Owned by the backend: sign-in, switching and signing out write them.
        obj.remove("accounts");
        obj.remove("known_servers");
    }
    cfg
}

/// Saved accounts as the webview may see them: everything but a file-mode
/// token.
fn redact_accounts(cfg: &mut Value) {
    if let Some(list) = cfg.get_mut("accounts").and_then(|v| v.as_array_mut()) {
        for a in list {
            if let Some(obj) = a.as_object_mut() {
                obj.remove("token");
                // A Seerr session filed here for want of a keyring.
                obj.remove("seerr");
            }
        }
    }
}

/// The stored token, for Rust-side requests. Reads the keyring first and falls
/// back to a config file left over from the plaintext era.
pub fn token() -> Option<String> {
    keyring_get().or_else(|| {
        crate::config::load()
            .get("token")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    })
}

/// Persist a freshly issued token. Falls back to the config file (now 0600)
/// when there's no usable keyring, matching `hydrate`'s degraded mode.
pub fn store(tok: &str) -> Result<(), String> {
    match keyring_set(tok) {
        Ok(()) => Ok(()),
        Err(e) => {
            crate::debug_log_line(&format!(
                "secret: keyring write failed ({}) — falling back to config.json",
                e
            ));
            crate::config::merge(json!({ "token": tok }))
        }
    }
}

/// Drop the local copy of the token, wherever it ended up.
pub fn clear() {
    if let Err(e) = keyring_clear() {
        crate::debug_log_line(&format!("secret: keyring clear failed: {}", e));
    }
    let _ = crate::config::merge(json!({ "token": null }));
}

/// Park a token whose revocation hasn't been accepted by the server yet, along
/// with where to send the retry. Kept in the keyring rather than on disk — it
/// is still a live credential until the server says otherwise.
///
/// These three take the same lock as the token, so a startup that checks for a
/// parked revocation while the first API calls are going out still only ever
/// has one Secret Service conversation open at a time.
pub fn park_pending_revocation(token: &str, server: &str, device_id: &str) -> Result<(), String> {
    let mut st = state();
    let blob = json!({ "token": token, "server": server, "device_id": device_id });
    write(PENDING_ACCOUNT, &blob.to_string())?;
    st.pending = Some(Some(blob));
    Ok(())
}

/// Answered from the cache after the first lookup, failed lookups included,
/// for the same reason as `cached_token`.
pub fn pending_revocation() -> Option<Value> {
    let mut st = state();
    if let Some(known) = &st.pending {
        return known.clone();
    }
    let found = match read(PENDING_ACCOUNT).map(|v| v.or_else(|| adopt_legacy(PENDING_ACCOUNT))) {
        Ok(v) => v.and_then(|s| serde_json::from_str::<Value>(&s).ok()),
        Err(e) => {
            crate::debug_log_line(&format!("secret: pending-revocation read failed: {}", e));
            None
        }
    };
    st.pending = Some(found.clone());
    found
}

pub fn clear_pending_revocation() {
    let mut st = state();
    // Only a wipe that worked proves nothing is parked any more.
    if wipe(PENDING_ACCOUNT).is_ok() {
        st.pending = Some(None);
    }
}

/// Whether the keyring is actually usable, for the Settings readout. Answered
/// from whatever the last real lookup or write proved; if nothing has touched
/// it yet, one lookup settles it. This used to probe on every call, which made
/// the Settings screen and `app_info` each worth a password prompt of their
/// own.
pub fn backend_name() -> &'static str {
    let mut st = state();
    if let Some(known) = st.backend {
        return known;
    }
    cached_token(&mut st);
    st.backend.unwrap_or("file")
}

// ---------- Other accounts on this device ----------
//
// The account in use keeps its token under `ACCOUNT`, exactly where it always
// has, so everything above (the cache, the legacy adoption, the plaintext
// migration) carries on unchanged. Every saved account also has a slot of its
// own, `jellyfin-access-token:<account key>`, which is what makes switching
// back to it a click rather than a password. Switching copies the slot into
// `ACCOUNT`; signing an account out of this device wipes its slot.

fn slot(key: &str) -> String {
    format!("{ACCOUNT}:{key}")
}

/// File the token for one saved account. With no usable keyring the token
/// goes into that account's entry in config.json instead, the same degraded
/// mode `store` falls back to.
pub fn store_account(key: &str, tok: &str) -> Result<(), String> {
    let _st = state();
    match write(&slot(key), tok) {
        Ok(()) => Ok(()),
        Err(e) => {
            crate::debug_log_line(&format!(
                "secret: keyring write for a saved account failed ({}) — falling back to config.json",
                e
            ));
            crate::config::set_account_field(key, "token", json!(tok))
        }
    }
}

/// A saved account's token, from its keyring slot or, failing that, from its
/// config entry.
pub fn account_token(key: &str) -> Option<String> {
    let from_keyring = {
        let _st = state();
        read(&slot(key)).ok().flatten()
    };
    from_keyring.or_else(|| {
        crate::config::accounts()
            .into_iter()
            .find(|a| a.get("key").and_then(|v| v.as_str()) == Some(key))
            .and_then(|a| a.get("token").and_then(|v| v.as_str()).map(str::to_owned))
            .filter(|s| !s.is_empty())
    })
}

pub fn clear_account(key: &str) {
    {
        let _st = state();
        if let Err(e) = wipe(&slot(key)) {
            crate::debug_log_line(&format!("secret: keyring clear for a saved account failed: {}", e));
        }
    }
    let _ = crate::config::set_account_field(key, "token", Value::Null);
}

// ---------- Seerr sessions ----------
//
// One per Jellyfin account, beside that account's token and under the same
// rules: the keyring first, the account's config entry when there is no
// keyring, one D-Bus conversation at a time, and never across the IPC
// boundary (`redact_accounts` strips the file copy; nothing returns the
// keyring one to the webview). What is filed is one JSON blob, written and
// read by `seerr.rs`.

fn seerr_slot(key: &str) -> String {
    format!("{SEERR_ACCOUNT}:{key}")
}

fn remember_seerr(st: &mut State, key: &str, value: Option<String>) {
    st.seerr.retain(|(k, _)| k != key);
    st.seerr.push((key.to_owned(), value));
}

fn seerr_in_file(key: &str) -> Option<String> {
    crate::config::accounts()
        .into_iter()
        .find(|a| a.get("key").and_then(|v| v.as_str()) == Some(key))
        .and_then(|a| a.get("seerr").and_then(|v| v.as_str()).map(str::to_owned))
        .filter(|s| !s.is_empty())
}

/// File an account's Seerr session. With no usable keyring it goes into that
/// account's entry in config.json, the degraded mode `store_account` has; an
/// account with no entry has nowhere to put it, and that is an error.
pub fn store_seerr(key: &str, blob: &str) -> Result<(), String> {
    let mut st = state();
    let stored = match write(&seerr_slot(key), blob) {
        Ok(()) => Ok(()),
        Err(e) => {
            crate::debug_log_line(&format!(
                "secret: keyring write for a Seerr session failed ({}) — falling back to config.json",
                e
            ));
            let listed = crate::config::accounts()
                .iter()
                .any(|a| a.get("key").and_then(|v| v.as_str()) == Some(key));
            if listed {
                crate::config::set_account_field(key, "seerr", json!(blob))
            } else {
                Err("no saved account to file the Seerr session under".to_string())
            }
        }
    };
    if stored.is_ok() {
        remember_seerr(&mut st, key, Some(blob.to_owned()));
    }
    stored
}

/// An account's Seerr session, from memory after the first lookup (a miss
/// and a failed lookup are remembered too, for the reason `cached_token`
/// gives), from its keyring slot or, failing that, its config entry.
pub fn seerr_session(key: &str) -> Option<String> {
    let mut st = state();
    if let Some((_, known)) = st.seerr.iter().find(|(k, _)| k == key) {
        return known.clone();
    }
    let found = match read(&seerr_slot(key)) {
        Ok(Some(v)) => Some(v),
        Ok(None) => seerr_in_file(key),
        Err(e) => {
            crate::debug_log_line(&format!("secret: Seerr session lookup failed: {}", e));
            seerr_in_file(key)
        }
    };
    remember_seerr(&mut st, key, found.clone());
    found
}

pub fn clear_seerr(key: &str) {
    let mut st = state();
    if let Err(e) = wipe(&seerr_slot(key)) {
        crate::debug_log_line(&format!("secret: Seerr session removal from the keyring failed: {}", e));
    }
    let _ = crate::config::set_account_field(key, "seerr", Value::Null);
    remember_seerr(&mut st, key, None);
}

/// Built only by the Linux crate (D-Bus). The test sandbox points the session
/// and system buses at a socket that doesn't exist, so everything here except
/// the `#[ignore]`d tests exercises the no-keyring fallback. The ignored ones
/// need a real Secret Service and only touch items of their own:
///   AQUARIUM_TEST_REAL_DBUS=1 cargo test --lib secret -- --ignored
#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{config_on_disk, debug_log, sandbox};

    // ---------- What an item is filed under ----------

    #[test]
    fn items_keep_the_attributes_the_keyring_crate_wrote() {
        // Changing any of these orphans the token already in a user's keyring.
        assert_eq!(
            attrs("acct"),
            HashMap::from([
                ("service", "dev.aquarium.app"),
                ("username", "acct"),
                ("target", "default"),
                ("application", "rust-keyring"),
            ])
        );
        // Searches are narrower, so items from before `target` still match.
        assert_eq!(
            search_attrs("acct"),
            HashMap::from([("service", "dev.aquarium.app"), ("username", "acct")])
        );
        assert_eq!(label("acct"), "acct@dev.aquarium.app:default");
        assert_eq!(ACCOUNT, "jellyfin-access-token");
        assert_eq!(PENDING_ACCOUNT, "jellyfin-pending-revocation");
        assert_eq!(slot("k1"), "jellyfin-access-token:k1");
        assert_eq!(seerr_slot("k1"), "seerr-session:k1");
    }

    #[test]
    fn the_legacy_fellyjin_service_is_still_searched() {
        // Invariant (Linux/CLAUDE.md): LEGACY_SERVICE/adopt_legacy keep
        // FellyJin installs signed in.
        assert_eq!(LEGACY_SERVICE, "dev.fellyjin.app");
        assert_eq!(
            search_attrs_in(LEGACY_SERVICE, ACCOUNT),
            HashMap::from([("service", "dev.fellyjin.app"), ("username", "jellyfin-access-token")])
        );
    }

    // ---------- No keyring: the config.json fallback ----------

    #[test]
    fn without_a_keyring_a_new_token_goes_to_the_config_file() {
        let _s = sandbox();
        store("tok-1").unwrap();
        assert_eq!(config_on_disk()["token"], json!("tok-1"));
        assert_eq!(backend_name(), "file");
        assert_eq!(token().as_deref(), Some("tok-1"));
        assert!(debug_log().contains("falling back to config.json"), "{}", debug_log());
    }

    #[test]
    fn a_failed_keyring_lookup_is_remembered() {
        // Regression: the token cache. Without it every request was its own
        // Secret Service lookup, and against a locked keyring its own prompt.
        let _s = sandbox();
        assert_eq!(token(), None);
        assert_eq!(token(), None);
        assert_eq!(backend_name(), "file");
        let log = debug_log();
        assert_eq!(log.matches("keyring read failed").count(), 1, "{log}");
    }

    #[test]
    fn backend_name_settles_with_one_lookup() {
        let _s = sandbox();
        assert_eq!(backend_name(), "file");
        assert_eq!(backend_name(), "file");
        assert_eq!(debug_log().matches("keyring read failed").count(), 1);
    }

    #[test]
    fn a_plaintext_token_stays_put_when_there_is_no_keyring() {
        let _s = sandbox();
        crate::config::save(&json!({
            "device_id": "d",
            "server": "http://jf",
            "token": "plain",
            "accounts": [{ "key": "a", "token": "acct-tok", "user_name": "Ann" }],
        }))
        .unwrap();
        let cfg = hydrate(crate::config::load());
        // The webview never sees a token.
        assert!(cfg.get("token").is_none());
        assert!(cfg["accounts"][0].get("token").is_none());
        assert_eq!(cfg["accounts"][0]["user_name"], json!("Ann"));
        assert_eq!(cfg["has_token"], json!(true));
        assert_eq!(cfg["token_storage"], json!("file"));
        // ...and the only copy is not dropped from disk.
        assert_eq!(config_on_disk()["token"], json!("plain"));
        assert!(debug_log().contains("token stays in config.json"));
        assert_eq!(token().as_deref(), Some("plain"));
    }

    #[test]
    fn hydrate_says_whether_there_is_a_session() {
        let _s = sandbox();
        let cfg = hydrate(json!({ "server": "http://jf", "token": "" }));
        assert_eq!(cfg["has_token"], json!(false));
        assert_eq!(cfg["token_storage"], json!("file"));
        assert!(cfg.get("token").is_none() || cfg["token"] == json!(""));
        assert_eq!(cfg["server"], json!("http://jf"));
    }

    #[test]
    fn dehydrate_drops_everything_the_backend_owns() {
        let out = dehydrate(json!({
            "token": "t", "token_storage": "file", "has_token": true,
            "accounts": [], "known_servers": [], "hwdec": "auto",
        }));
        assert_eq!(out, json!({ "hwdec": "auto" }));
        // A save without a token is not a sign-out.
        assert_eq!(dehydrate(json!({ "hwdec": "off" })), json!({ "hwdec": "off" }));
        assert_eq!(dehydrate(json!(null)), json!(null));
    }

    #[test]
    fn clear_removes_the_file_copy_even_without_a_keyring() {
        let _s = sandbox();
        store("tok").unwrap();
        clear();
        assert!(config_on_disk().get("token").is_none());
        assert_eq!(token(), None);
        assert!(debug_log().contains("keyring clear failed"));
    }

    #[test]
    fn a_revocation_cannot_be_parked_without_a_keyring_and_the_miss_is_cached() {
        // Regression: 6210523. app_info asks on every sidebar redraw; each ask
        // used to be another keyring read.
        let _s = sandbox();
        assert!(park_pending_revocation("t", "http://jf", "d").is_err());
        assert_eq!(pending_revocation(), None);
        assert_eq!(pending_revocation(), None);
        assert_eq!(debug_log().matches("pending-revocation read failed").count(), 1);
        clear_pending_revocation();
        assert_eq!(pending_revocation(), None);
    }

    #[test]
    fn nothing_to_adopt_without_a_keyring() {
        let _s = sandbox();
        assert_eq!(adopt_legacy(ACCOUNT), None);
        assert!(read_in(LEGACY_SERVICE, ACCOUNT).is_err());
    }

    #[test]
    fn saved_account_tokens_fall_back_to_their_config_entry() {
        let _s = sandbox();
        crate::config::upsert_account(json!({ "key": "k", "user_name": "Ann" })).unwrap();
        store_account("k", "acct-tok").unwrap();
        let entry = crate::config::accounts().into_iter().find(|a| a["key"] == "k").unwrap();
        assert_eq!(entry["token"], json!("acct-tok"));
        assert_eq!(account_token("k").as_deref(), Some("acct-tok"));
        assert!(debug_log().contains("keyring write for a saved account failed"));
        clear_account("k");
        assert_eq!(account_token("k"), None);
        let entry = crate::config::accounts().into_iter().find(|a| a["key"] == "k").unwrap();
        assert!(entry.get("token").is_none());
        assert_eq!(entry["user_name"], json!("Ann"), "the account itself stays");
        assert_eq!(account_token("nobody"), None);
    }

    #[test]
    fn a_saved_account_token_needs_its_entry_first() {
        // Regression: 13ea908. Without a keyring the token is written into
        // the account's config entry, so filing it before the entry existed
        // dropped it; server.rs now saves the entry first. This pins the
        // reason that order matters.
        let _s = sandbox();
        store_account("k", "acct-tok").unwrap();
        crate::config::upsert_account(json!({ "key": "k" })).unwrap();
        assert_eq!(account_token("k"), None);
    }

    // ---------- Seerr sessions ----------

    #[test]
    fn a_seerr_session_falls_back_to_its_accounts_config_entry() {
        let _s = sandbox();
        crate::config::upsert_account(json!({ "key": "k", "user_name": "Ann" })).unwrap();
        store_seerr("k", "{\"cookie\":\"s%3Aone\"}").unwrap();
        let entry = crate::config::accounts().into_iter().find(|a| a["key"] == "k").unwrap();
        assert_eq!(entry["seerr"], json!("{\"cookie\":\"s%3Aone\"}"));
        assert_eq!(seerr_session("k").as_deref(), Some("{\"cookie\":\"s%3Aone\"}"));
        assert!(debug_log().contains("keyring write for a Seerr session failed"));
        // The webview's copy of the config never carries it.
        let seen = hydrate(crate::config::load());
        assert!(!seen.to_string().contains("s%3Aone"), "{seen}");
        assert_eq!(seen["accounts"][0]["user_name"], json!("Ann"));
        clear_seerr("k");
        assert_eq!(seerr_session("k"), None);
        let entry = crate::config::accounts().into_iter().find(|a| a["key"] == "k").unwrap();
        assert!(entry.get("seerr").is_none());
        assert_eq!(entry["user_name"], json!("Ann"), "the account itself stays");
    }

    #[test]
    fn a_seerr_session_with_nowhere_to_go_is_an_error() {
        let _s = sandbox();
        assert!(store_seerr("nobody", "{}").is_err());
        assert_eq!(seerr_session("nobody"), None);
    }

    #[test]
    fn a_seerr_lookup_is_made_once_per_account() {
        let _s = sandbox();
        assert_eq!(seerr_session("k"), None);
        assert_eq!(seerr_session("k"), None);
        assert_eq!(debug_log().matches("Seerr session lookup failed").count(), 1);
        // Another account is its own lookup.
        assert_eq!(seerr_session("other"), None);
        assert_eq!(debug_log().matches("Seerr session lookup failed").count(), 2);
    }

    // ---------- A real Secret Service (opt-in) ----------

    fn real_bus() -> bool {
        if !crate::test_support::real_dbus() {
            eprintln!("skipped: needs AQUARIUM_TEST_REAL_DBUS=1 and a session keyring");
            return false;
        }
        true
    }

    /// An account name no real item uses, so these never touch the user's token.
    fn scratch_account() -> String {
        format!("aquarium-test-{}", uuid::Uuid::new_v4())
    }

    #[test]
    #[ignore = "needs a real Secret Service: AQUARIUM_TEST_REAL_DBUS=1 cargo test --lib secret -- --ignored"]
    fn a_fellyjin_item_is_adopted_and_the_old_one_removed() {
        if !real_bus() {
            return;
        }
        let acct = scratch_account();
        with_collection(|c| {
            c.create_item("aquarium test (legacy)", search_attrs_in(LEGACY_SERVICE, &acct), b"legacy-tok", true, "text/plain")
                .map(|_| ())
        })
        .expect("could not file a legacy item");
        let adopted = adopt_legacy(&acct);
        let now = read_in(SERVICE, &acct);
        let old = read_in(LEGACY_SERVICE, &acct);
        let _ = wipe_in(SERVICE, &acct);
        let _ = wipe_in(LEGACY_SERVICE, &acct);
        assert_eq!(adopted.as_deref(), Some("legacy-tok"));
        assert_eq!(now, Ok(Some("legacy-tok".to_string())), "not filed under the new service");
        assert_eq!(old, Ok(None), "the FellyJin copy was left behind");
    }

    #[test]
    #[ignore = "needs a real Secret Service: AQUARIUM_TEST_REAL_DBUS=1 cargo test --lib secret -- --ignored"]
    fn writing_twice_overwrites_in_place() {
        if !real_bus() {
            return;
        }
        let acct = scratch_account();
        write(&acct, "one").expect("write");
        write(&acct, "two").expect("overwrite");
        let count = with_collection(|c| Ok(c.search_items(search_attrs(&acct))?.len()));
        let value = read(&acct);
        wipe(&acct).expect("wipe");
        let after = read(&acct);
        assert_eq!(count.ok(), Some(1), "a second, competing item was filed");
        assert_eq!(value, Ok(Some("two".to_string())));
        assert_eq!(after, Ok(None));
        // Wiping nothing is success.
        assert_eq!(wipe(&acct), Ok(()));
    }
}
