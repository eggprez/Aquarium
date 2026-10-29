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
}
