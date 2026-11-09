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
    let Ok(sock) = UdpSocket::bind("0.0.0.0:0") else { return vec![] };
    if sock.set_broadcast(true).is_err() {
        return vec![];
    }
    // recv wakes every 250 ms so the deadline holds on a silent network.
    let _ = sock.set_read_timeout(Some(Duration::from_millis(250)));

    let targets = broadcast_targets();
    let send_all = |sock: &UdpSocket| {
        targets
            .iter()
            .filter(|t| sock.send_to(QUESTION, SocketAddrV4::new(**t, PORT)).is_ok())
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
            let bcast = ifa.ifa_ifu;
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
}
