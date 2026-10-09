//  Settings that follow you between devices.
//
//  Two Apple TVs in one house are the case this exists for: the same Jellyfin
//  server, the same playlist addresses, the same subtitle size, typed twice on
//  a remote control. `NSUbiquitousKeyValueStore` carries all of that — it is a
//  small dictionary iCloud replicates, with no server of our own involved.
//
//  What it deliberately does not carry: the access token, which goes through
//  iCloud Keychain instead (see `Keychain`), and this device's own id, volume
//  and last route, which are about the box rather than about the account.

import Foundation

enum CloudSync {
    /// Whether there is anywhere to sync to.
    ///
    /// `synchronize()` answers false when the app has no ubiquity key-value
    /// entitlement — a build signed without iCloud turned on for the App ID —
    /// and also when nobody is signed in to iCloud. Asked once: neither of
    /// those becomes true later in the life of the process, and every read and
    /// write below is a no-op when it is false, so a build without the
    /// entitlement behaves exactly as this app did before.
    static let isAvailable: Bool = NSUbiquitousKeyValueStore.default.synchronize()

    private static var store: NSUbiquitousKeyValueStore { .default }

    /// The settings that travel. Everything not named here stays on the device
    /// that set it.
    ///
    /// `volume`, `device_id`, `last_route` and `recent_searches` are left out
    /// on purpose. A device id shared between two Apple TVs makes them one
    /// session as far as Jellyfin is concerned, and the other three describe
    /// the box in front of you rather than the account behind it.
    static let syncedKeys: Set<String> = [
        "theme",
        "adaptive", "autoplay_next", "stereo_downmix",
        "home_combine_next_up", "next_up_hidden",
        // No `audio_delay`: it is the lag of one room's soundbar, and two
        // Apple TVs are two rooms. No `default_bitrate` either: the quality a
        // device can stream at is its network's, not the household's. Nor
        // `download_concurrency`: how many transfers at once suits an iPad on
        // home Wi-Fi is not what suits a phone on cellular.
        "resume_playback",
        "audio_lang", "sub_lang", "subs_forced_only",
        "sub_font_size", "sub_bg",
        "fill_screen",
        "livetv_source", "iptv_playlist_url", "iptv_guide_url", "iptv_refresh_minutes", "iptv_user_agent",
        "download_quality", "downloads_wifi_only",
        "music_lossless_cellular", "music_autoplay", "music_normalize", "audiobook_speed",
        "music_mix_points",
        "smart_playlists",
        "tab_bar_order",
        Self.sessionKey,
    ]

    /// Where the signed-in server and user go. A separate key from the local
    /// `session` because what travels is not the same value: the device id is
    /// stripped out of it. See `Preferences.cloudSession`.
    static let sessionKey = "session.shared"

    static func set(_ value: Any?, forKey key: String) {
        guard isAvailable, syncedKeys.contains(key) else { return }
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    static func object(forKey key: String) -> Any? {
        guard isAvailable else { return nil }
        return store.object(forKey: key)
    }

    static func data(forKey key: String) -> Data? { object(forKey: key) as? Data }

    /// Nudge iCloud to send what has been written. Not required — the store
    /// pushes on its own schedule — but it makes "changed it here, walked to
    /// the other room" behave the way people expect.
    static func flush() {
        guard isAvailable else { return }
        store.synchronize()
    }

    /// Fires when another device changed something.
    static let changed = NSUbiquitousKeyValueStore.didChangeExternallyNotification
}
