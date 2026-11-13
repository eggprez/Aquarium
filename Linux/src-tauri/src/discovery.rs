//! Finding a Jellyfin server on the local network.
//!
//! Jellyfin listens on UDP 7359 and answers "who is JellyfinServer?" with a
//! line of JSON naming itself and the address it would like to be reached at.
//! That is the whole protocol — no mDNS, no SSDP — so this is one datagram out
//! and a short wait for whatever comes back.
//!
//! The question goes to 255.255.255.255 and, separately, to every interface's
//! own broadcast address: the limited broadcast leaves by the default route
//! only, which on a laptop with Wi-Fi and a VPN (or a dock's Ethernet) up is
//! not necessarily the network the server is on.

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::time::{Duration, Instant};

const QUESTION: &[u8] = b"who is JellyfinServer?";
const PORT: u16 = 7359;
/// Anything on the network can answer; a home network plausibly has a
/// handful of servers, and the list is drawn, so a flood is cut off.
const MAX_SERVERS: usize = 16;

/// Ask, and gather answers for about `timeout`. Blocking; run it off the
/// async runtime.
pub fn find(timeout: Duration) -> Vec<Value> {
    find_from(broadcast_targets, PORT, timeout)
}

/// `find`, with where the question goes passed in. Split out for tests, which
/// ask a responder on 127.0.0.1 instead of the network.
fn find_from(targets: fn() -> Vec<Ipv4Addr>, port: u16, timeout: Duration) -> Vec<Value> {
    let Ok(sock) = UdpSocket::bind("0.0.0.0:0") else { return vec![] };
    if sock.set_broadcast(true).is_err() {
        return vec![];
    }
    // recv wakes every 250 ms so the deadline holds on a silent network.
    let _ = sock.set_read_timeout(Some(Duration::from_millis(250)));

    let targets = targets();
    let send_all = |sock: &UdpSocket| {
        targets
            .iter()
            .filter(|t| sock.send_to(QUESTION, SocketAddrV4::new(**t, port)).is_ok())
            .count()
    };
    if send_all(&sock) == 0 {
        return vec![];
    }

    let mut found: BTreeMap<String, (String, String)> = BTreeMap::new();
    let mut buf = [0u8; 4096];
    let started = Instant::now();
    let mut resent = false;
    while started.elapsed() < timeout {
        // A second copy half-way through: UDP promises nothing, and Wi-Fi
        // drops broadcasts more readily than anything else.
        if !resent && started.elapsed() > timeout / 2 {
            resent = true;
            send_all(&sock);
        }
        let Ok((n, _)) = sock.recv_from(&mut buf) else { continue };
        let Some((id, name, address)) = parse_reply(&buf[..n]) else { continue };
        if found.contains_key(&id) || found.len() < MAX_SERVERS {
            found.insert(id, (name, address));
        }
    }
    let mut out: Vec<Value> = found
        .into_iter()
        .map(|(id, (name, address))| json!({ "id": id, "name": name, "address": address }))
        .collect();
    out.sort_by_key(|v| v["name"].as_str().unwrap_or_default().to_lowercase());
    out
}

/// `(id, name, address)` from one answer, or `None` for anything that isn't a
/// plain http(s) address.
fn parse_reply(bytes: &[u8]) -> Option<(String, String, String)> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    let address = v.get("Address")?.as_str()?.trim().to_string();
    let normalized = crate::server::normalize(&address).ok()?;
    let id = v
        .get("Id")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| normalized.clone());
    let name: String = v
        .get("Name")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or(&normalized)
        .chars()
        .take(80)
        .collect();
    Some((id, name, normalized))
}

/// 255.255.255.255 plus the broadcast address of every IPv4 interface that is
/// up, isn't loopback and has one.
fn broadcast_targets() -> Vec<Ipv4Addr> {
    let mut targets = vec![Ipv4Addr::BROADCAST];
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs fills `list` with a linked list we walk read-only and
    // hand back to freeifaddrs exactly once.
    unsafe {
        if libc::getifaddrs(&mut list) != 0 {
            return targets;
        }
        let mut cur = list;
        while !cur.is_null() {
            let ifa = &*cur;
            cur = ifa.ifa_next;
            let flags = ifa.ifa_flags as libc::c_int;
            if flags & libc::IFF_UP == 0
                || flags & libc::IFF_BROADCAST == 0
                || flags & libc::IFF_LOOPBACK != 0
                || ifa.ifa_addr.is_null()
                || (*ifa.ifa_addr).sa_family as libc::c_int != libc::AF_INET
            {
                continue;
            }
            // On Linux the broadcast address lives in the union glibc names
            // `ifa_ifu` (ifu_broadaddr when IFF_BROADCAST is set).
            #[cfg(target_os = "linux")]
            let bcast = ifa.ifa_ifu;
            // The BSDs (and so a Mac running the unit tests) call the same
            // slot `ifa_dstaddr`.
            #[cfg(not(target_os = "linux"))]
            let bcast = ifa.ifa_dstaddr;
            if bcast.is_null() || (*bcast).sa_family as libc::c_int != libc::AF_INET {
                continue;
            }
            let sin = &*(bcast as *const libc::sockaddr_in);
            let ip = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
            if !ip.is_unspecified() && !targets.contains(&ip) {
                targets.push(ip);
            }
        }
        libc::freeifaddrs(list);
    }
    targets
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_jellyfin_answer() {
        let r = br#"{"Address":"http://192.168.1.10:8096","Id":"abc","Name":"Den","EndpointAddress":null}"#;
        assert_eq!(
            parse_reply(r),
            Some(("abc".into(), "Den".into(), "http://192.168.1.10:8096".into()))
        );
    }

    #[test]
    fn ignores_answers_that_are_not_web_addresses() {
        assert_eq!(parse_reply(br#"{"Address":"file:///etc/passwd","Id":"x"}"#), None);
        assert_eq!(parse_reply(b"not json"), None);
        assert_eq!(parse_reply(br#"{"Id":"x"}"#), None);
    }

    #[test]
    fn always_asks_the_limited_broadcast() {
        assert_eq!(broadcast_targets()[0], Ipv4Addr::BROADCAST);
    }

    #[test]
    fn interface_broadcasts_are_listed_once_and_never_unspecified() {
        let t = broadcast_targets();
        assert!(!t.contains(&Ipv4Addr::UNSPECIFIED));
        assert!(!t.contains(&Ipv4Addr::LOCALHOST), "loopback has no broadcast to ask");
        let mut d = t.clone();
        d.sort();
        d.dedup();
        assert_eq!(d.len(), t.len(), "{t:?}");
    }

    #[test]
    fn answers_are_cleaned_up() {
        // No id: the address stands in. No name: the address again.
        assert_eq!(
            parse_reply(br#"{"Address":" http://10.0.0.2:8096/ "}"#),
            Some(("http://10.0.0.2:8096".into(), "http://10.0.0.2:8096".into(), "http://10.0.0.2:8096".into()))
        );
        assert_eq!(
            parse_reply(br#"{"Address":"https://jf.lan","Id":"","Name":""}"#),
            Some(("https://jf.lan".into(), "https://jf.lan".into(), "https://jf.lan".into()))
        );
        // A name is drawn in a list: a long one is cut at 80 characters.
        let long = "x".repeat(200);
        let reply = format!(r#"{{"Address":"http://h","Id":"i","Name":"{long}"}}"#);
        assert_eq!(parse_reply(reply.as_bytes()).unwrap().1.chars().count(), 80);
        // Credentials in the address are not an address to offer.
        assert_eq!(parse_reply(br#"{"Address":"http://u:p@h","Id":"i"}"#), None);
        assert_eq!(parse_reply(br#"{"Address":42,"Id":"i"}"#), None);
    }

    // ---------- `find`, against a responder on this machine ----------

    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;

    struct Responder {
        port: u16,
        questions: Arc<AtomicUsize>,
        stop: Arc<AtomicBool>,
    }

    impl Drop for Responder {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
        }
    }

    /// Answers each "who is JellyfinServer?" with every datagram `replies`
    /// gives for that question's number (from 1), and ignores anything else.
    fn responder(replies: impl Fn(usize) -> Vec<String> + Send + 'static) -> Responder {
        let sock = UdpSocket::bind("127.0.0.1:0").unwrap();
        sock.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let port = sock.local_addr().unwrap().port();
        let questions = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (q, s) = (questions.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut buf = [0u8; 512];
            while !s.load(Ordering::SeqCst) {
                let Ok((n, from)) = sock.recv_from(&mut buf) else { continue };
                if &buf[..n] != QUESTION {
                    continue;
                }
                let k = q.fetch_add(1, Ordering::SeqCst) + 1;
                for r in replies(k) {
                    let _ = sock.send_to(r.as_bytes(), from);
                }
            }
        });
        Responder { port, questions, stop }
    }

    fn localhost() -> Vec<Ipv4Addr> {
        vec![Ipv4Addr::LOCALHOST]
    }

    fn reply(id: &str, name: &str, address: &str) -> String {
        json!({ "Id": id, "Name": name, "Address": address }).to_string()
    }

    #[test]
    fn finds_servers_sorted_by_name_and_asks_twice() {
        let r = responder(|_| {
            vec![
                reply("b", "basement", "http://10.0.0.2:8096"),
                reply("a", "Attic", "http://10.0.0.1:8096"),
                "garbage".into(),
                reply("c", "Cupboard", "ftp://10.0.0.3"),
            ]
        });
        let found = find_from(localhost, r.port, Duration::from_millis(1200));
        assert_eq!(
            found,
            vec![
                json!({ "id": "a", "name": "Attic", "address": "http://10.0.0.1:8096" }),
                json!({ "id": "b", "name": "basement", "address": "http://10.0.0.2:8096" }),
            ],
            "sorted without regard to case, garbage and non-web addresses dropped, repeats folded"
        );
        // A second copy of the question goes out half-way: UDP promises nothing.
        assert_eq!(r.questions.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_flood_of_answers_is_cut_off() {
        let r = responder(|k| {
            (0..20).map(|i| reply(&format!("{k}-{i:02}"), &format!("s{k}-{i:02}"), "http://10.0.0.9")).collect()
        });
        let found = find_from(localhost, r.port, Duration::from_millis(1200));
        assert_eq!(found.len(), MAX_SERVERS);
    }

    #[test]
    fn a_server_already_listed_can_still_update_past_the_cap() {
        // The 16 slots fill on the first question; the second round renames
        // one already in the list, which is kept rather than refused.
        let r = responder(|k| {
            let mut v: Vec<String> =
                (0..MAX_SERVERS).map(|i| reply(&format!("id{i:02}"), &format!("n{i:02}"), "http://10.0.0.9")).collect();
            if k > 1 {
                v.push(reply("id00", "renamed", "http://10.0.0.10"));
                v.push(reply("new", "newcomer", "http://10.0.0.11"));
            }
            v
        });
        let found = find_from(localhost, r.port, Duration::from_millis(1200));
        assert_eq!(found.len(), MAX_SERVERS);
        let first = found.iter().find(|v| v["id"] == "id00").unwrap();
        assert_eq!(first["name"], json!("renamed"));
        assert!(!found.iter().any(|v| v["id"] == "new"));
    }

    #[test]
    fn nothing_to_ask_is_an_empty_answer_at_once() {
        let started = Instant::now();
        assert!(find_from(Vec::new, 9, Duration::from_secs(30)).is_empty());
        assert!(started.elapsed() < Duration::from_secs(30));
    }

    #[test]
    fn a_silent_network_answers_empty_after_the_wait() {
        let r = responder(|_| Vec::new());
        assert!(find_from(localhost, r.port, Duration::from_millis(300)).is_empty());
    }
}
