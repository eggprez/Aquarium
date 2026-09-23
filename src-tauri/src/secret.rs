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
}

/// Held across the blocking Secret Service call on purpose: a second caller
/// that arrives mid-unlock waits and then reads the answer out of the cache,
/// instead of opening its own connection and queueing a second password
/// prompt behind the first.
static STATE: Mutex<State> = Mutex::new(State {
    token: None,
    backend: None,
});

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
        return cfg;
    }

    cfg["has_token"] = json!(keyring_get().is_some());
    cfg["token_storage"] = json!(backend_name());
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
    }
    cfg
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
    let _guard = state();
    let blob = json!({ "token": token, "server": server, "device_id": device_id }).to_string();
    write(PENDING_ACCOUNT, &blob)
}

pub fn pending_revocation() -> Option<Value> {
    let _guard = state();
    match read(PENDING_ACCOUNT).map(|v| v.or_else(|| adopt_legacy(PENDING_ACCOUNT))) {
        Ok(v) => v.and_then(|s| serde_json::from_str::<Value>(&s).ok()),
        Err(e) => {
            crate::debug_log_line(&format!("secret: pending-revocation read failed: {}", e));
            None
        }
    }
}

pub fn clear_pending_revocation() {
    let _guard = state();
    let _ = wipe(PENDING_ACCOUNT);
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
