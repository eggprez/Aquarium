//! The parts of a download that aren't the transfer itself: its subtitles,
//! keeping its details current with the server, and showing it in Files.

use crate::{config, downloads};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

// ---------- Subtitles ----------
//
// A transcoded download carries no subtitles at all (the server encodes one
// picture and one sound track), and an original file carries only what is
// inside it, never the `.srt` the server keeps beside it. So every text
// subtitle the server knows of is fetched as a file next to the video, and a
// small index says what each one is. Picture subtitles (PGS, VobSub) have no
// text to convert and are left out; inside an original MKV they play anyway.

/// The index beside the media.
const SUB_INDEX: &str = "subtitles.json";
/// Goes before an index with gaps in it is left as it is. Some streams the
/// server always refuses (closed captions read out of the video, a codec it
/// can't convert), and without a limit every refresh would ask again.
const SUB_MAX_ATTEMPTS: u64 = 3;

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

/// What to ask the server to convert to: ASS keeps its styling, which mpv
/// draws as written; everything else is plain SRT.
fn sub_format(codec: &str) -> &'static str {
    match codec.to_ascii_lowercase().as_str() {
        "ass" | "ssa" => "ass",
        _ => "srt",
    }
}

/// `sub.3.eng.forced.srt`. mpv reads the language (and from 0.38 the
/// "forced" flag) out of the name, which is all a menu has to go on offline.
fn sub_file_name(index: u64, lang: Option<&str>, forced: bool, fmt: &str) -> String {
    let lang: String = lang
        .unwrap_or("und")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .take(16)
        .collect();
    let lang = if lang.is_empty() { "und".into() } else { lang };
    format!("sub.{index}.{lang}{}.{fmt}", if forced { ".forced" } else { "" })
}

/// Fetch every text subtitle of a download into its folder. Safe to call
/// again and cheap once done: a complete index ends it before the network,
/// and a file already there isn't fetched twice. `original` downloads keep
/// their embedded tracks, so only the server's external files are wanted.
pub async fn fetch_subtitles(item_id: &str, original: bool) {
    let Ok(dir) = downloads::item_dir(item_id) else { return };
    let earlier = read_json(&dir.join(SUB_INDEX));
    if earlier.as_ref().and_then(|v| v.get("complete")).and_then(|v| v.as_bool()) == Some(true) {
        return;
    }
    let Some(user) = config::load().get("user_id").and_then(|v| v.as_str()).map(String::from) else {
        return;
    };
    let item = match crate::server::request(&format!("/Items/{item_id}?userId={user}"), None, None).await {
        Ok(v) if v["status"] == 200 => v["body"].clone(),
        _ => return,
    };
    let Some(source) = item["MediaSources"].get(0) else { return };
    let source_id = source["Id"].as_str().unwrap_or(item_id).to_string();
    let streams = source["MediaStreams"].as_array().cloned().unwrap_or_default();

    let mut entries = Vec::new();
    let mut complete = true;
    for st in streams.iter().filter(|s| {
        s["Type"] == "Subtitle"
            && s["IsTextSubtitleStream"] == true
            && (!original || s["IsExternal"] == true)
    }) {
        let Some(index) = st["Index"].as_u64() else { continue };
        let fmt = sub_format(st["Codec"].as_str().unwrap_or(""));
        let lang = st["Language"].as_str();
        let forced = st["IsForced"] == true;
        let file = sub_file_name(index, lang, forced, fmt);
        let path = dir.join(&file);
        if !path.exists() {
            let url = format!("/Videos/{item_id}/{source_id}/Subtitles/{index}/0/Stream.{fmt}");
            match crate::server::get_bytes(&url).await {
                Ok(bytes) if !bytes.is_empty() && dir.exists() => {
                    if std::fs::write(&path, &bytes).is_err() {
                        complete = false;
                        continue;
                    }
                }
                Ok(_) => {
                    complete = false;
                    continue;
                }
                Err(e) => {
                    crate::debug_log_line(&format!("subtitle {index} of {item_id} not fetched: {e}"));
                    complete = false;
                    continue;
                }
            }
        }
        entries.push(json!({
            "index": index,
            "file": file,
            "lang": lang,
            "title": st["DisplayTitle"].as_str().or(st["Title"].as_str()),
            "default": st["IsDefault"] == true,
            "forced": forced,
            "external": st["IsExternal"] == true,
        }));
    }
    // Deleted while this ran: nothing to write into.
    if !dir.exists() {
        return;
    }
    let attempts = earlier.as_ref().and_then(|v| v["attempts"].as_u64()).unwrap_or(0) + 1;
    let index = json!({
        "media_source_id": source_id,
        "entries": entries,
        "complete": complete || attempts >= SUB_MAX_ATTEMPTS,
        "attempts": attempts,
    });
    if let Ok(s) = serde_json::to_string_pretty(&index) {
        let _ = std::fs::write(dir.join(SUB_INDEX), s);
    }
    crate::debug_log_line(&format!("subtitles for {item_id}: {} file(s)", entries.len()));
}

/// The subtitle files beside a download that are actually there, for
/// `downloads_list` and from there the player.
pub fn local_subtitles(dir: &Path) -> Vec<Value> {
    let Some(index) = read_json(&dir.join(SUB_INDEX)) else { return Vec::new() };
    index["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|e| {
            let path = dir.join(e["file"].as_str()?);
            path.exists().then(|| {
                let mut e = e.clone();
                e["path"] = json!(path.to_string_lossy());
                e
            })
        })
        .collect()
}

/// The saved subtitles for a downloaded video at `video`, defaults first.
pub fn subtitles_for(video: &str) -> Vec<Value> {
    let Some(dir) = Path::new(video).parent() else { return Vec::new() };
    if !dir.starts_with(config::downloads_dir()) {
        return Vec::new();
    }
    let mut subs = local_subtitles(dir);
    subs.sort_by_key(|e| !(e["default"] == true));
    subs
}

/// The `sub-add` commands for a download's saved subtitles, once its file has
/// loaded. At most one is selected, standing in for what mpv's own pick would
/// have done had the tracks been inside the file: nothing when Settings says
/// never, or when a track inside the file is already showing; otherwise the
/// first match for the preferred languages (`sub_lang`, mpv's `slang` list),
/// or with no preference the track the server marks default.
pub fn sub_add_commands(subs: &[Value], slang: &str, embedded_on: bool) -> Vec<Value> {
    let lang_of = |e: &Value| e["lang"].as_str().unwrap_or("").to_ascii_lowercase();
    let pick: Option<usize> = if slang == "off" || embedded_on {
        None
    } else if !slang.is_empty() {
        slang.split(',').map(|l| l.trim().to_ascii_lowercase()).find_map(|want| {
            subs.iter()
                .position(|e| lang_of(e) == want && e["forced"] != true)
                .or_else(|| subs.iter().position(|e| lang_of(e) == want))
        })
    } else {
        subs.iter().position(|e| e["default"] == true)
    };
    subs.iter()
        .enumerate()
        .filter_map(|(i, e)| {
            let path = e["path"].as_str()?;
            let title = e["title"].as_str().unwrap_or("");
            let lang = e["lang"].as_str().unwrap_or("");
            let flag = if Some(i) == pick { "select" } else { "auto" };
            Some(json!(["sub-add", path, flag, title, lang]))
        })
        .collect()
}

/// Whether a download has had its subtitles looked for in full yet.
pub fn subtitles_settled(dir: &Path) -> bool {
    read_json(&dir.join(SUB_INDEX)).and_then(|v| v["complete"].as_bool()) == Some(true)
}

// ---------- Details refresh ----------

/// Keys of meta.json the server is allowed to refresh. Anything else (the
/// stored request, the file name, the status) belongs to the download.
const DETAIL_KEYS: &[&str] = &[
    "name", "title", "overview", "series", "season", "episode", "year", "run_time_ticks",
    "image_tag", "series_image_tag", "details_at",
];

/// Merge refreshed details into a download's meta.json and replace any
/// artwork whose URL is given (the caller only passes one when the server's
/// image tag has changed). Watch state goes through `set_watch_state`.
pub async fn update_details(
    item_id: &str,
    patch: &Value,
    poster_url: Option<String>,
    series_poster_url: Option<String>,
) -> Result<(), String> {
    let dir = downloads::item_dir(item_id)?;
    let meta_path = dir.join("meta.json");
    let mut meta = read_json(&meta_path).ok_or("no download metadata for this item")?;
    if let Some(p) = patch.as_object() {
        for (k, v) in p {
            if DETAIL_KEYS.contains(&k.as_str()) {
                meta[k] = v.clone();
            }
        }
    }
    for (url, file) in [(poster_url, "poster.jpg"), (series_poster_url, "series_poster.jpg")] {
        if let Some(url) = url {
            replace_image(&url, &dir.join(file)).await;
        }
    }
    // Re-read so a status change that landed meanwhile isn't overwritten.
    let mut current = read_json(&meta_path).unwrap_or(meta.clone());
    for k in DETAIL_KEYS {
        if let Some(v) = meta.get(*k) {
            current[*k] = v.clone();
        }
    }
    let s = serde_json::to_string_pretty(&current).map_err(|e| e.to_string())?;
    std::fs::write(&meta_path, s).map_err(|e| e.to_string())
}

/// Fetch an image over the old one, through a temporary file so a failed
/// fetch leaves the old artwork rather than nothing.
async fn replace_image(url: &str, path: &Path) {
    let Ok(resp) = crate::jellyfin::http().get(url).timeout(Duration::from_secs(30)).send().await else {
        return;
    };
    if !resp.status().is_success() {
        return;
    }
    let Ok(bytes) = resp.bytes().await else { return };
    if bytes.is_empty() {
        return;
    }
    let tmp = path.with_extension("jpg.new");
    if std::fs::write(&tmp, &bytes).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

// ---------- Show in Files ----------

/// `file://` URI for a path, percent-encoding everything outside the
/// unreserved set (and `/`).
fn file_uri(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;
    let mut out = String::from("file://");
    for &b in path.as_os_str().as_bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// What to point the file manager at for a set of downloads: the video file
/// itself for one finished item, otherwise each item's folder (they all sit
/// side by side in the downloads folder, so one window shows them selected).
fn reveal_targets(item_ids: &[String]) -> Vec<PathBuf> {
    let dirs: Vec<PathBuf> = item_ids
        .iter()
        .filter_map(|id| downloads::item_dir(id).ok())
        .filter(|d| d.exists())
        .collect();
    if let [dir] = dirs.as_slice() {
        let file = read_json(&dir.join("meta.json"))
            .and_then(|m| m["file"].as_str().map(|f| dir.join(f)))
            .filter(|f| f.exists());
        return vec![file.unwrap_or_else(|| dir.clone())];
    }
    dirs
}

/// Show downloads in the file manager, selected. Through the FileManager1
/// D-Bus interface (Nautilus, Dolphin, Nemo, Thunar…), falling back to opening
/// the folder when nothing answers it.
pub fn reveal(item_ids: &[String]) -> Result<(), String> {
    let targets = reveal_targets(item_ids);
    if targets.is_empty() {
        return Err("Nothing on disk to show".into());
    }
    let uris: Vec<String> = targets.iter().map(|p| file_uri(p)).collect();
    #[cfg(target_os = "linux")]
    {
        let shown = dbus::blocking::Connection::new_session().and_then(|conn| {
            conn.with_proxy(
                "org.freedesktop.FileManager1",
                "/org/freedesktop/FileManager1",
                Duration::from_secs(3),
            )
            .method_call::<(), _, _, _>("org.freedesktop.FileManager1", "ShowItems", (uris, ""))
        });
        if shown.is_ok() {
            return Ok(());
        }
    }
    // No D-Bus off Linux (the portable test build); straight to the fallback.
    #[cfg(not(target_os = "linux"))]
    let _ = uris;
    let folder = if targets.len() == 1 {
        let t = &targets[0];
        if t.is_dir() { t.clone() } else { t.parent().map(Path::to_path_buf).unwrap_or_default() }
    } else {
        config::downloads_dir()
    };
    std::process::Command::new("xdg-open")
        .arg(&folder)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Couldn't open the folder: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subtitle_names_carry_language_and_forced() {
        assert_eq!(sub_file_name(3, Some("eng"), false, "srt"), "sub.3.eng.srt");
        assert_eq!(sub_file_name(4, None, true, "ass"), "sub.4.und.forced.ass");
        assert_eq!(sub_file_name(5, Some("../x"), false, "srt"), "sub.5.x.srt");
        assert_eq!(sub_format("SSA"), "ass");
        assert_eq!(sub_format("subrip"), "srt");
    }

    #[test]
    fn one_saved_subtitle_is_picked_like_mpv_would() {
        let subs = vec![
            json!({"path": "/d/sub.2.eng.srt", "lang": "eng", "title": "English", "forced": true}),
            json!({"path": "/d/sub.3.eng.srt", "lang": "eng", "title": "English SDH"}),
            json!({"path": "/d/sub.4.fra.srt", "lang": "fra", "title": "French", "default": true}),
        ];
        let flags = |slang: &str, on: bool| -> Vec<String> {
            sub_add_commands(&subs, slang, on).iter().map(|c| c[2].as_str().unwrap().to_string()).collect()
        };
        // Preferred language: the full track over the forced one.
        assert_eq!(flags("eng", false), ["auto", "select", "auto"]);
        assert_eq!(flags("jpn,fra", false), ["auto", "auto", "select"]);
        // No preference: the server's default.
        assert_eq!(flags("", false), ["auto", "auto", "select"]);
        // Never, or a track inside the file already showing.
        assert_eq!(flags("off", false), ["auto", "auto", "auto"]);
        assert_eq!(flags("eng", true), ["auto", "auto", "auto"]);
        assert_eq!(sub_add_commands(&subs, "", false)[1], json!(["sub-add", "/d/sub.3.eng.srt", "auto", "English SDH", "eng"]));
    }

    #[test]
    fn file_uris_are_percent_encoded() {
        assert_eq!(
            file_uri(Path::new("/home/a b/Ep #1 (720p).mkv")),
            "file:///home/a%20b/Ep%20%231%20%28720p%29.mkv"
        );
    }

    #[test]
    fn file_uris_encode_every_byte_outside_the_unreserved_set() {
        assert_eq!(file_uri(Path::new("/d/Amélie_1-2.~x")), "file:///d/Am%C3%A9lie_1-2.~x");
        assert_eq!(file_uri(Path::new("/a%b?c&d")), "file:///a%25b%3Fc%26d");
    }

    #[test]
    fn subtitle_names_are_safe_and_bounded() {
        assert_eq!(sub_file_name(1, Some(""), false, "srt"), "sub.1.und.srt");
        assert_eq!(sub_file_name(1, Some("///"), false, "srt"), "sub.1.und.srt");
        assert_eq!(sub_file_name(1, Some("pt-BR"), false, "srt"), "sub.1.pt-BR.srt");
        assert_eq!(sub_file_name(1, Some(&"a".repeat(40)), false, "srt"), format!("sub.1.{}.srt", "a".repeat(16)));
        assert_eq!(sub_format("ASS"), "ass");
        assert_eq!(sub_format("webvtt"), "srt");
        assert_eq!(sub_format(""), "srt");
    }

    #[test]
    fn sub_add_commands_edge_cases() {
        // Only a forced track in the wanted language: that one, rather than none.
        let subs = vec![json!({"path": "/d/a.srt", "lang": "ENG", "forced": true})];
        assert_eq!(sub_add_commands(&subs, " eng ", false)[0][2], json!("select"));
        // Entries without a file are skipped; missing title and language are empty.
        let subs = vec![json!({"lang": "eng"}), json!({"path": "/d/b.srt"})];
        assert_eq!(sub_add_commands(&subs, "", false), vec![json!(["sub-add", "/d/b.srt", "auto", "", ""])]);
        // Nothing matches the preference: nothing selected.
        let subs = vec![json!({"path": "/d/c.srt", "lang": "fra", "default": true})];
        assert_eq!(sub_add_commands(&subs, "deu", false)[0][2], json!("auto"));
        assert!(sub_add_commands(&[], "eng", false).is_empty());
    }

    // ---------- With a download folder and a server ----------

    use crate::test_support::{debug_log, sandbox, sign_in, FakeServer, Req, Resp};

    fn item_folder(id: &str) -> PathBuf {
        let dir = config::downloads_dir().join(id);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sub(index: u64, codec: &str, lang: Option<&str>, text: bool, external: bool) -> Value {
        json!({
            "Type": "Subtitle", "Index": index, "Codec": codec, "Language": lang,
            "IsTextSubtitleStream": text, "IsExternal": external,
            "DisplayTitle": format!("Track {index}"),
        })
    }

    /// An item with one source `src1` and these streams.
    fn item(streams: Vec<Value>) -> Value {
        json!({ "Id": "item1", "MediaSources": [{ "Id": "src1", "MediaStreams": streams }] })
    }

    /// A Jellyfin that knows `item` and serves `sub_body(index)` for each
    /// subtitle (`None` = 500).
    fn server_with(item: Value, sub_body: fn(u64) -> Option<Vec<u8>>) -> FakeServer {
        FakeServer::jellyfin(move |req: &Req| {
            let p = req.path();
            if p == "/Items/item1" {
                return Resp::json(200, item.clone());
            }
            if let Some(rest) = p.strip_prefix("/Videos/item1/src1/Subtitles/") {
                let index: u64 = rest.split('/').next().unwrap().parse().unwrap();
                return match sub_body(index) {
                    Some(b) => Resp::bytes(200, "text/plain", b),
                    None => Resp::status(500),
                };
            }
            Resp::status(404)
        })
    }

    fn index_of(dir: &Path) -> Value {
        read_json(&dir.join(SUB_INDEX)).unwrap_or(Value::Null)
    }

    fn sub_requests(s: &FakeServer) -> Vec<String> {
        s.requests().into_iter().filter(|r| r.path().contains("/Subtitles/")).map(|r| r.path().to_string()).collect()
    }

    #[tokio::test]
    async fn a_transcode_gets_every_text_subtitle_as_a_file() {
        let _s = sandbox();
        let streams = vec![
            json!({ "Type": "Audio", "Index": 1 }),
            sub(2, "subrip", Some("eng"), true, false),
            {
                let mut s = sub(3, "ass", Some("fra"), true, true);
                s["IsForced"] = json!(true);
                s["IsDefault"] = json!(true);
                s["DisplayTitle"] = Value::Null;
                s["Title"] = json!("Signs");
                s
            },
            sub(4, "PGSSUB", Some("eng"), false, false),
        ];
        let server = server_with(item(streams), |i| Some(format!("subtitle {i}").into_bytes()));
        sign_in(&server.url);
        let dir = item_folder("item1");

        fetch_subtitles("item1", false).await;

        assert_eq!(std::fs::read_to_string(dir.join("sub.2.eng.srt")).unwrap(), "subtitle 2");
        assert_eq!(std::fs::read_to_string(dir.join("sub.3.fra.forced.ass")).unwrap(), "subtitle 3");
        assert!(!dir.join("sub.4.eng.srt").exists(), "picture subtitles have no text to fetch");
        let mut asked = sub_requests(&server);
        asked.sort();
        assert_eq!(
            asked,
            vec!["/Videos/item1/src1/Subtitles/2/0/Stream.srt", "/Videos/item1/src1/Subtitles/3/0/Stream.ass"]
        );
        let idx = index_of(&dir);
        assert_eq!(idx["media_source_id"], json!("src1"));
        assert_eq!(idx["complete"], json!(true));
        assert_eq!(idx["attempts"], json!(1));
        assert_eq!(
            idx["entries"],
            json!([
                { "index": 2, "file": "sub.2.eng.srt", "lang": "eng", "title": "Track 2", "default": false, "forced": false, "external": false },
                { "index": 3, "file": "sub.3.fra.forced.ass", "lang": "fra", "title": "Signs", "default": true, "forced": true, "external": true },
            ])
        );
        assert!(subtitles_settled(&dir));
        assert!(debug_log().contains("subtitles for item1: 2 file(s)"));

        // Done is done: another call doesn't go near the server.
        server.forget_requests();
        fetch_subtitles("item1", false).await;
        assert!(server.requests().is_empty());
    }

    #[tokio::test]
    async fn an_original_file_only_wants_the_servers_external_files() {
        let _s = sandbox();
        let server = server_with(
            item(vec![sub(2, "subrip", Some("eng"), true, false), sub(3, "srt", Some("deu"), true, true)]),
            |_| Some(b"x".to_vec()),
        );
        sign_in(&server.url);
        let dir = item_folder("item1");
        fetch_subtitles("item1", true).await;
        assert_eq!(sub_requests(&server), vec!["/Videos/item1/src1/Subtitles/3/0/Stream.srt"]);
        assert!(dir.join("sub.3.deu.srt").exists());
        assert!(!dir.join("sub.2.eng.srt").exists());
    }

    #[tokio::test]
    async fn a_file_already_there_is_not_fetched_again() {
        let _s = sandbox();
        let server = server_with(item(vec![sub(2, "srt", Some("eng"), true, false)]), |_| Some(b"new".to_vec()));
        sign_in(&server.url);
        let dir = item_folder("item1");
        std::fs::write(dir.join("sub.2.eng.srt"), "kept").unwrap();
        fetch_subtitles("item1", false).await;
        assert!(sub_requests(&server).is_empty());
        assert_eq!(std::fs::read_to_string(dir.join("sub.2.eng.srt")).unwrap(), "kept");
        assert_eq!(index_of(&dir)["entries"][0]["file"], json!("sub.2.eng.srt"));
    }

    #[tokio::test]
    async fn refused_subtitles_are_asked_for_three_times_then_left() {
        // Regression: 251c55d. Some streams the server always refuses; without
        // a limit every refresh would ask again.
        let _s = sandbox();
        let server = server_with(
            item(vec![sub(2, "srt", Some("eng"), true, false), sub(3, "srt", Some("fra"), true, false), sub(5, "srt", None, true, false)]),
            |i| match i {
                2 => Some(b"ok".to_vec()),
                3 => None,         // the server fails
                _ => Some(vec![]), // an empty answer is no subtitle either
            },
        );
        sign_in(&server.url);
        let dir = item_folder("item1");
        for attempt in 1..=3u64 {
            fetch_subtitles("item1", false).await;
            let idx = index_of(&dir);
            assert_eq!(idx["attempts"], json!(attempt));
            assert_eq!(idx["complete"], json!(attempt == 3), "attempt {attempt}");
            assert_eq!(idx["entries"].as_array().unwrap().len(), 1, "only the fetched one is listed");
        }
        assert!(subtitles_settled(&dir));
        assert!(!dir.join("sub.5.und.srt").exists());
        assert!(debug_log().contains("subtitle 3 of item1 not fetched"));
        server.forget_requests();
        fetch_subtitles("item1", false).await;
        assert!(server.requests().is_empty(), "a settled index is not asked again");
    }

    #[tokio::test]
    async fn a_download_deleted_mid_fetch_is_not_recreated() {
        // "Deleted while this ran: nothing to write into."
        let _s = sandbox();
        let dir = item_folder("item1");
        let doomed = dir.clone();
        let it = item(vec![sub(2, "srt", Some("eng"), true, false)]);
        let server = FakeServer::jellyfin(move |req| {
            if req.path() == "/Items/item1" {
                return Resp::json(200, it.clone());
            }
            let _ = std::fs::remove_dir_all(&doomed);
            Resp::bytes(200, "text/plain", b"late".to_vec())
        });
        sign_in(&server.url);
        fetch_subtitles("item1", false).await;
        assert!(!dir.exists(), "the deleted download came back");
    }

    #[tokio::test]
    async fn nothing_is_fetched_without_what_it_needs() {
        let _s = sandbox();
        let server = server_with(item(vec![sub(2, "srt", Some("eng"), true, false)]), |_| Some(b"x".to_vec()));
        let dir = item_folder("item1");
        // Not signed in: no user id.
        fetch_subtitles("item1", false).await;
        assert!(server.requests().is_empty());
        // Not an id.
        sign_in(&server.url);
        fetch_subtitles("../item1", false).await;
        assert!(server.requests_to("/Items/../item1").is_empty());
        assert_eq!(index_of(&dir), Value::Null);

        // The item can't be read, or has no sources.
        server.set_handler(|req| match req.path() {
            "/System/Info/Public" => Resp::json(200, json!({ "Id": crate::test_support::FAKE_SERVER_ID })),
            "/Items/item1" => Resp::status(404),
            _ => Resp::status(500),
        });
        fetch_subtitles("item1", false).await;
        assert_eq!(index_of(&dir), Value::Null);
        server.set_handler(|req| match req.path() {
            "/System/Info/Public" => Resp::json(200, json!({ "Id": crate::test_support::FAKE_SERVER_ID })),
            "/Items/item1" => Resp::json(200, json!({ "Id": "item1", "MediaSources": [] })),
            _ => Resp::status(500),
        });
        fetch_subtitles("item1", false).await;
        assert_eq!(index_of(&dir), Value::Null);
    }

    #[test]
    fn local_subtitles_lists_only_files_that_are_there() {
        let _s = sandbox();
        let dir = item_folder("item1");
        assert!(local_subtitles(&dir).is_empty(), "no index, nothing");
        std::fs::write(dir.join("sub.2.eng.srt"), "x").unwrap();
        std::fs::write(
            dir.join(SUB_INDEX),
            json!({ "complete": false, "entries": [
                { "index": 2, "file": "sub.2.eng.srt", "lang": "eng" },
                { "index": 3, "file": "sub.3.fra.srt", "lang": "fra" },
                { "index": 4 },
            ]})
            .to_string(),
        )
        .unwrap();
        let subs = local_subtitles(&dir);
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0]["lang"], json!("eng"));
        assert_eq!(subs[0]["path"], json!(dir.join("sub.2.eng.srt").to_string_lossy()));
        assert!(!subtitles_settled(&dir));
        std::fs::write(dir.join(SUB_INDEX), "not json").unwrap();
        assert!(local_subtitles(&dir).is_empty());
        assert!(!subtitles_settled(&dir));
    }

    #[test]
    fn subtitles_for_a_video_puts_the_default_first_and_stays_inside_downloads() {
        let _s = sandbox();
        let dir = item_folder("item1");
        for f in ["sub.2.eng.srt", "sub.3.fra.srt"] {
            std::fs::write(dir.join(f), "x").unwrap();
        }
        std::fs::write(
            dir.join(SUB_INDEX),
            json!({ "complete": true, "entries": [
                { "index": 2, "file": "sub.2.eng.srt" },
                { "index": 3, "file": "sub.3.fra.srt", "default": true },
            ]})
            .to_string(),
        )
        .unwrap();
        let video = dir.join("video.mkv");
        let subs = subtitles_for(&video.to_string_lossy());
        assert_eq!(subs.iter().map(|s| s["index"].as_u64().unwrap()).collect::<Vec<_>>(), vec![3, 2]);

        // The same layout outside the downloads folder is not read.
        let outside = config::data_dir().join("elsewhere");
        std::fs::create_dir_all(&outside).unwrap();
        for f in ["sub.2.eng.srt", SUB_INDEX] {
            std::fs::copy(dir.join(f), outside.join(f)).unwrap();
        }
        assert!(subtitles_for(&outside.join("v.mkv").to_string_lossy()).is_empty());
        assert!(subtitles_for("https://jf/stream.mkv").is_empty());
        assert!(subtitles_for("/").is_empty());
    }

    /// Against the live QA server (read-only): the server's sidecar text
    /// subtitles come down through the route this builds, picture ones don't.
    #[tokio::test]
    async fn qa_server_sidecar_subtitles_are_saved() {
        crate::test_support::with_qa_session(|_qa, _who| async move {
            let item = crate::test_support::qa_find_item("Movie", "FX Sidecar Subs", "MediaSources")
                .await
                .expect("the QA library has FX Sidecar Subs");
            let id = item["Id"].as_str().unwrap().to_string();
            let dir = item_folder(&id);
            fetch_subtitles(&id, true).await;
            let idx = index_of(&dir);
            assert_eq!(idx["complete"], json!(true), "{idx}");
            let entries = idx["entries"].as_array().unwrap();
            let text_sidecars = item["MediaSources"][0]["MediaStreams"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|s| s["Type"] == "Subtitle" && s["IsExternal"] == true && s["IsTextSubtitleStream"] == true)
                .count();
            assert!(text_sidecars >= 2, "the fixture should have several text sidecars");
            assert_eq!(entries.len(), text_sidecars);
            for e in entries {
                let f = dir.join(e["file"].as_str().unwrap());
                assert!(std::fs::metadata(&f).map(|m| m.len() > 0).unwrap_or(false), "{} is empty", f.display());
            }
            assert!(entries.iter().any(|e| e["file"].as_str().unwrap().ends_with(".ass")), "ASS should stay ASS");
            assert!(!entries.iter().any(|e| e["lang"] == "ita"), "the PGS sidecar has no text");
            let subs = subtitles_for(&dir.join("video.mkv").to_string_lossy());
            assert_eq!(subs.len(), entries.len());
        })
        .await;
    }

    // ---------- Details refresh ----------

    #[tokio::test]
    async fn details_refresh_touches_only_the_details() {
        let _s = sandbox();
        let dir = item_folder("item1");
        std::fs::write(
            dir.join("meta.json"),
            json!({ "name": "Old", "file": "video.mkv", "status": "done", "request": { "x": 1 } }).to_string(),
        )
        .unwrap();
        update_details(
            "item1",
            &json!({ "name": "New", "overview": "o", "year": 2020, "file": "../../evil", "status": "failed", "path": "/etc" }),
            None,
            None,
        )
        .await
        .unwrap();
        let m = read_json(&dir.join("meta.json")).unwrap();
        assert_eq!(m["name"], json!("New"));
        assert_eq!(m["overview"], json!("o"));
        assert_eq!(m["year"], json!(2020));
        assert_eq!(m["file"], json!("video.mkv"), "the server may not rename the file");
        assert_eq!(m["status"], json!("done"));
        assert_eq!(m["request"], json!({ "x": 1 }));
        assert!(m.get("path").is_none());
        for k in DETAIL_KEYS {
            assert!(!["file", "status", "path", "request", "played", "position_ticks"].contains(k));
        }
    }

    #[tokio::test]
    async fn details_refresh_needs_a_download() {
        let _s = sandbox();
        assert!(update_details("item1", &json!({}), None, None).await.is_err());
        assert!(update_details("..", &json!({}), None, None).await.is_err());
    }

    #[tokio::test]
    async fn new_artwork_replaces_the_old_and_a_failed_fetch_keeps_it() {
        let _s = sandbox();
        let dir = item_folder("item1");
        std::fs::write(dir.join("meta.json"), r#"{"name":"x"}"#).unwrap();
        std::fs::write(dir.join("poster.jpg"), "old poster").unwrap();
        std::fs::write(dir.join("series_poster.jpg"), "old series").unwrap();
        let server = FakeServer::start(|req| match req.path() {
            "/new.jpg" => Resp::bytes(200, "image/jpeg", b"new poster".to_vec()),
            "/empty.jpg" => Resp::bytes(200, "image/jpeg", vec![]),
            _ => Resp::status(404),
        });
        update_details("item1", &json!({}), Some(format!("{}/new.jpg", server.url)), Some(format!("{}/gone.jpg", server.url)))
            .await
            .unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("poster.jpg")).unwrap(), "new poster");
        assert_eq!(std::fs::read_to_string(dir.join("series_poster.jpg")).unwrap(), "old series");
        update_details("item1", &json!({}), Some(format!("{}/empty.jpg", server.url)), Some(FakeServer::dead_url()))
            .await
            .unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("poster.jpg")).unwrap(), "new poster");
        assert_eq!(std::fs::read_to_string(dir.join("series_poster.jpg")).unwrap(), "old series");
        assert!(!dir.join("poster.jpg.new").exists());
        assert!(!dir.join("series_poster.jpg.new").exists());
    }

    #[tokio::test]
    async fn a_status_change_during_the_refresh_is_not_lost() {
        // "Re-read so a status change that landed meanwhile isn't overwritten."
        let _s = sandbox();
        let dir = item_folder("item1");
        let meta = dir.join("meta.json");
        std::fs::write(&meta, json!({ "name": "Old", "status": "downloading" }).to_string()).unwrap();
        let during = meta.clone();
        let server = FakeServer::start(move |_| {
            // The transfer finishes while the poster is on its way.
            std::fs::write(&during, json!({ "name": "Old", "status": "done" }).to_string()).unwrap();
            Resp::bytes(200, "image/jpeg", b"p".to_vec())
        });
        update_details("item1", &json!({ "name": "New" }), Some(format!("{}/p.jpg", server.url)), None)
            .await
            .unwrap();
        let m = read_json(&meta).unwrap();
        assert_eq!(m["status"], json!("done"));
        assert_eq!(m["name"], json!("New"));
    }

    // ---------- Show in Files ----------

    #[test]
    fn one_finished_download_is_shown_as_its_file() {
        let _s = sandbox();
        let dir = item_folder("item1");
        std::fs::write(dir.join("meta.json"), r#"{"file":"Ep 1.mkv"}"#).unwrap();
        std::fs::write(dir.join("Ep 1.mkv"), "v").unwrap();
        assert_eq!(reveal_targets(&["item1".into()]), vec![dir.join("Ep 1.mkv")]);
        // The file not there (yet): its folder.
        std::fs::remove_file(dir.join("Ep 1.mkv")).unwrap();
        assert_eq!(reveal_targets(&["item1".into()]), vec![dir.clone()]);
        std::fs::remove_file(dir.join("meta.json")).unwrap();
        assert_eq!(reveal_targets(&["item1".into()]), vec![dir]);
    }

    #[test]
    fn several_downloads_are_shown_as_their_folders() {
        let _s = sandbox();
        let a = item_folder("a");
        let b = item_folder("b");
        std::fs::write(a.join("meta.json"), r#"{"file":"v.mkv"}"#).unwrap();
        std::fs::write(a.join("v.mkv"), "v").unwrap();
        let ids: Vec<String> = ["a", "b", "missing", "../.."].iter().map(|s| s.to_string()).collect();
        assert_eq!(reveal_targets(&ids), vec![a, b]);
        assert!(reveal_targets(&["missing".into()]).is_empty());
    }

    #[test]
    fn nothing_on_disk_is_an_error() {
        let _s = sandbox();
        assert_eq!(reveal(&["missing".into()]), Err("Nothing on disk to show".into()));
        assert_eq!(reveal(&[]), Err("Nothing on disk to show".into()));
    }

    /// Off Linux there is no FileManager1 to ask, so `reveal` goes straight to
    /// `xdg-open`, which a Mac doesn't have. (On Linux this would open a real
    /// file manager window, so it is not run there.)
    #[cfg(not(target_os = "linux"))]
    #[test]
    fn without_a_file_manager_it_falls_back_to_opening_the_folder() {
        let _s = sandbox();
        let on_path = std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).any(|d| d.join("xdg-open").exists()))
            .unwrap_or(false);
        if on_path {
            eprintln!("skipped: xdg-open is installed here and would open a window");
            return;
        }
        item_folder("item1");
        let err = reveal(&["item1".into()]).unwrap_err();
        assert!(err.starts_with("Couldn't open the folder"), "{err}");
    }
}
