//! The desktop's ways into the app besides its window: launcher actions
//! (the `.desktop` file's Continue Watching, Shuffle Music and Resume
//! Audiobook, which run `aquarium --action=<name>`) and GNOME Shell's search
//! (`aquarium --search-provider`, started by D-Bus activation). The Apple
//! app's counterparts are Spotlight, the icon's press-and-hold menu and the
//! App Shortcuts.
//!
//! An action reaches the running app over D-Bus when there is one
//! (`dev.aquarium.app`, `Activate`), so a launcher action never opens a second
//! window; with none running the app starts and takes the action once its
//! page is up (`take_launch_action`).
//!
//! The search provider answers from a file, not from the server: the app
//! writes the names of the library's films and shows to `search-index.json`
//! when it runs. The shell asks on every keystroke and gives up on a provider
//! that is slow, and a provider that had to unlock the keyring and reach the
//! server could be neither quick nor quiet. Signing out removes the file.

use dbus::arg::{PropMap, Variant};
use dbus::blocking::Connection;
use dbus::channel::MatchingReceiver;
use dbus::message::MatchRule;
use dbus_crossroads::Crossroads;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

const APP_BUS: &str = "dev.aquarium.app";
const APP_PATH: &str = "/dev/aquarium/app";
const SEARCH_BUS: &str = "dev.aquarium.app.SearchProvider";
const SEARCH_PATH: &str = "/dev/aquarium/app/SearchProvider";
const SEARCH_IFACE: &str = "org.gnome.Shell.SearchProvider2";
/// The shell shows a handful per provider; more is work nobody sees.
const MAX_RESULTS: usize = 8;
/// How long the provider stays up with nothing asked of it. The shell starts
/// it again on the next search.
const SEARCH_IDLE: Duration = Duration::from_secs(30);

/// An action given on the command line, waiting for the page to take it.
static PENDING: Mutex<Option<String>> = Mutex::new(None);

/// Only these shapes are acted on: an action arrives from outside the app.
fn valid_action(action: &str) -> bool {
    match action.split_once(':') {
        None => matches!(action, "continue" | "shuffle-music" | "resume-book"),
        Some(("open", id)) => !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'),
        Some(("search", term)) => !term.is_empty() && term.len() <= 200,
        _ => false,
    }
}

/// Hand `action` to a running instance. False when there is none to take it.
pub fn forward(action: &str) -> bool {
    if !valid_action(action) {
        return false;
    }
    let Ok(conn) = Connection::new_session() else { return false };
    let proxy = conn.with_proxy(APP_BUS, APP_PATH, Duration::from_secs(3));
    let sent: Result<(), dbus::Error> = proxy.method_call(APP_BUS, "Activate", (action,));
    sent.is_ok()
}

/// Keep `action` for the page to take once it is up.
pub fn set_pending(action: &str) {
    if valid_action(action) {
        *PENDING.lock().unwrap() = Some(action.to_string());
    }
}

pub fn take_pending() -> Option<String> {
    PENDING.lock().unwrap().take()
}

/// Serve `Activate` for as long as the app runs. A test instance (any
/// `AQUARIUM_TEST_*` hook) leaves the name alone, so launcher actions keep
/// going to the copy of the app the user is running.
pub fn start(app: AppHandle) {
    if std::env::vars().any(|(k, _)| k.starts_with("AQUARIUM_TEST_")) {
        return;
    }
    std::thread::spawn(move || {
        if let Err(e) = serve_app(app) {
            crate::debug_log_line(&format!("desktop: activation service unavailable: {e}"));
        }
    });
}

fn serve_app(app: AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let c = Connection::new_session()?;
    // Not replaced and not queued: the first instance keeps the name, and a
    // second one (opened by hand, with no action) simply goes without.
    c.request_name(APP_BUS, false, false, true)?;
    let mut cr = Crossroads::new();
    let iface = cr.register(APP_BUS, |b| {
        b.method("Activate", ("action",), (), |_, app: &mut AppHandle, (action,): (String,)| {
            if valid_action(&action) {
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.unminimize();
                    let _ = win.set_focus();
                }
                let _ = app.emit("launch-action", action);
            }
            Ok(())
        });
    });
    cr.insert(APP_PATH, &[iface], app);
    c.start_receive(
        MatchRule::new_method_call(),
        Box::new(move |msg, conn| {
            let _ = cr.handle_message(msg, conn);
            true
        }),
    );
    loop {
        c.process(Duration::from_secs(3600))?;
    }
}

// ---------------------------------------------------------------- the index

fn index_path() -> PathBuf {
    crate::config::data_dir().join("search-index.json")
}

/// One film or show, as the shell's search needs it.
#[derive(Clone)]
struct Entry {
    id: String,
    name: String,
    kind: String,
    year: Option<i64>,
}

/// Write the index the search provider answers from. Entries without an id
/// or a name are dropped; the write goes through a temporary file so the
/// provider never reads half of one.
pub fn write_index(items: &[Value]) -> Result<usize, String> {
    let rows: Vec<Value> = items
        .iter()
        .filter_map(|i| {
            let id = i.get("id")?.as_str()?;
            let name = i.get("name")?.as_str()?;
            if id.is_empty() || name.is_empty() {
                return None;
            }
            Some(serde_json::json!({
                "id": id,
                "name": name,
                "type": i.get("type").and_then(|t| t.as_str()).unwrap_or(""),
                "year": i.get("year").and_then(|y| y.as_i64()),
            }))
        })
        .collect();
    let path = index_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.part");
    std::fs::write(&tmp, serde_json::to_vec(&rows).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(rows.len())
}

/// Remove the index: at sign-out, so the library's titles do not stay
/// searchable from the desktop after the account has gone.
pub fn clear_index() {
    let _ = std::fs::remove_file(index_path());
}

fn read_index() -> Vec<Entry> {
    let Ok(bytes) = std::fs::read(index_path()) else { return Vec::new() };
    let Ok(Value::Array(rows)) = serde_json::from_slice::<Value>(&bytes) else { return Vec::new() };
    rows.iter()
        .filter_map(|r| {
            Some(Entry {
                id: r.get("id")?.as_str()?.to_string(),
                name: r.get("name")?.as_str()?.to_string(),
                kind: r.get("type").and_then(|t| t.as_str()).unwrap_or("").to_string(),
                year: r.get("year").and_then(|y| y.as_i64()),
            })
        })
        .collect()
}

/// Lower case, with accents folded away, so "amelie" finds "Amélie".
fn fold(s: &str) -> String {
    s.chars()
        .flat_map(|c| c.to_lowercase())
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
            'ç' => 'c',
            'è' | 'é' | 'ê' | 'ë' => 'e',
            'ì' | 'í' | 'î' | 'ï' => 'i',
            'ñ' => 'n',
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' => 'o',
            'ù' | 'ú' | 'û' | 'ü' => 'u',
            'ý' | 'ÿ' => 'y',
            other => other,
        })
        .collect()
}

/// The ids of the titles holding every term, best first: a title that starts
/// with the search, then one where a word does, then the rest by name.
fn search(index: &[Entry], terms: &[String]) -> Vec<String> {
    let terms: Vec<String> = terms.iter().map(|t| fold(t)).filter(|t| !t.is_empty()).collect();
    if terms.is_empty() {
        return Vec::new();
    }
    let whole = terms.join(" ");
    let mut hits: Vec<(u8, String, &Entry)> = index
        .iter()
        .filter_map(|e| {
            let name = fold(&e.name);
            if !terms.iter().all(|t| name.contains(t.as_str())) {
                return None;
            }
            let rank = if name.starts_with(&whole) {
                0
            } else if name.split_whitespace().any(|w| w.starts_with(terms[0].as_str())) {
                1
            } else {
                2
            };
            Some((rank, name, e))
        })
        .collect();
    hits.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    hits.into_iter().take(MAX_RESULTS).map(|(_, _, e)| e.id.clone()).collect()
}

fn describe(e: &Entry) -> String {
    let kind = match e.kind.as_str() {
        "Movie" => "Film",
        "Series" => "Show",
        other => other,
    };
    match (kind.is_empty(), e.year) {
        (false, Some(y)) => format!("{kind} · {y}"),
        (false, None) => kind.to_string(),
        (true, Some(y)) => y.to_string(),
        (true, None) => String::new(),
    }
}

/// Start the app (or reach the running one) with `action`.
fn launch(action: String) {
    if forward(&action) {
        return;
    }
    if let Ok(exe) = std::env::current_exe() {
        let _ = std::process::Command::new(exe).arg(format!("--action={action}")).spawn();
    }
}

/// `aquarium --search-provider`: GNOME Shell's search, answered from the
/// index. No window, no webview, no server; it leaves when the shell has
/// stopped asking.
pub fn run_search_provider() -> Result<(), Box<dyn std::error::Error>> {
    let c = Connection::new_session()?;
    c.request_name(SEARCH_BUS, false, true, true)?;
    let last = Arc::new(Mutex::new(Instant::now()));
    let mut cr = Crossroads::new();
    let iface = cr.register(SEARCH_IFACE, |b| {
        b.method("GetInitialResultSet", ("terms",), ("results",), |_, _: &mut (), (terms,): (Vec<String>,)| {
            Ok((search(&read_index(), &terms),))
        });
        // The shell passes the previous answer to narrow; searching the whole
        // index again is as cheap and never misses a better match.
        b.method(
            "GetSubsearchResultSet",
            ("previous", "terms"),
            ("results",),
            |_, _: &mut (), (_previous, terms): (Vec<String>, Vec<String>)| Ok((search(&read_index(), &terms),)),
        );
        b.method("GetResultMetas", ("ids",), ("metas",), |_, _: &mut (), (ids,): (Vec<String>,)| {
            let index = read_index();
            let metas: Vec<PropMap> = ids
                .iter()
                .filter_map(|id| index.iter().find(|e| &e.id == id))
                .map(|e| {
                    let mut m = PropMap::new();
                    m.insert("id".into(), Variant(Box::new(e.id.clone())));
                    m.insert("name".into(), Variant(Box::new(e.name.clone())));
                    m.insert("description".into(), Variant(Box::new(describe(e))));
                    // A themed icon by name: the app's own.
                    m.insert("gicon".into(), Variant(Box::new("aquarium".to_string())));
                    m
                })
                .collect();
            Ok((metas,))
        });
        b.method(
            "ActivateResult",
            ("id", "terms", "timestamp"),
            (),
            |_, _: &mut (), (id, _terms, _timestamp): (String, Vec<String>, u32)| {
                launch(format!("open:{id}"));
                Ok(())
            },
        );
        b.method("LaunchSearch", ("terms", "timestamp"), (), |_, _: &mut (), (terms, _timestamp): (Vec<String>, u32)| {
            launch(format!("search:{}", terms.join(" ")));
            Ok(())
        });
    });
    cr.insert(SEARCH_PATH, &[iface], ());
    let seen = last.clone();
    c.start_receive(
        MatchRule::new_method_call(),
        Box::new(move |msg, conn| {
            *seen.lock().unwrap() = Instant::now();
            let _ = cr.handle_message(msg, conn);
            true
        }),
    );
    while last.lock().unwrap().elapsed() < SEARCH_IDLE {
        c.process(Duration::from_secs(5))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, name: &str) -> Entry {
        Entry { id: id.into(), name: name.into(), kind: "Movie".into(), year: Some(2001) }
    }

    #[test]
    fn search_ranks_a_leading_match_first_and_folds_accents() {
        let index = vec![entry("a", "The Star"), entry("b", "Star Wars"), entry("c", "Amélie"), entry("d", "Lone Starlet")];
        assert_eq!(search(&index, &["star".into()]), vec!["b", "d", "a"]);
        assert_eq!(search(&index, &["amelie".into()]), vec!["c"]);
        assert_eq!(search(&index, &["star".into(), "wars".into()]), vec!["b"]);
        assert!(search(&index, &["".into()]).is_empty());
    }

    #[test]
    fn only_known_actions_are_taken() {
        assert!(valid_action("continue"));
        assert!(valid_action("open:a211b78d4919f370bda1241644d00ccb"));
        assert!(valid_action("search:star wars"));
        assert!(!valid_action("open:../../etc"));
        assert!(!valid_action("open:"));
        assert!(!valid_action("quit"));
        assert!(!valid_action("eval:alert(1)"));
    }
}
