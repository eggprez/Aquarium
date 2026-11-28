//! Playback preferences — the mpv-facing half of the Settings page.
//!
//! Everything here is read out of config.json at the moment a stream starts,
//! rather than held in memory, so a setting changed mid-episode applies to the
//! next one without any plumbing to invalidate.
//!
//! Options used to be checked against the mpv *binary*'s own `--list-options`
//! output first, because the command-line player exits with status 2 on an
//! option it doesn't recognise rather than warning and carrying on — one
//! stale option meant no playback at all. That doesn't apply any more:
//! options now go in one at a time through libmpv's option API
//! ([`mpv::Session::start`](crate::mpv::Session::start)'s `set` closure),
//! which already rejects an unknown name with nothing worse than a log line.
//! So every option below is passed through unconditionally, relying on that
//! per-option tolerance rather than re-implementing it here.

use serde_json::Value;

/// Settings' "Battery saver rendering".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BatteryRender {
    /// mpv's own high-quality chain, always.
    Off,
    /// The cheap chain, always — as command-line options, so it holds even
    /// without the bundled config dir.
    On,
    /// The cheap chain while the machine is on battery or in the power-saver
    /// profile, switched live through the `aquarium-battery` profile in the
    /// bundled mpv.conf (see `power.rs` and `Player::sync_battery_profile`).
    Auto,
}

/// The name of that profile in src-tauri/mpv-config/mpv.conf.
pub const BATTERY_PROFILE: &str = "aquarium-battery";

/// The playback half of config.json, with the defaults applied.
pub struct Prefs {
    cfg: Value,
}

impl Prefs {
    pub fn load() -> Self {
        Self {
            cfg: crate::config::load(),
        }
    }

    fn text(&self, key: &str) -> String {
        self.cfg
            .get(key)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string()
    }

    fn flag(&self, key: &str) -> bool {
        self.cfg.get(key).and_then(|v| v.as_bool()).unwrap_or(false)
    }

    /// Older configs stored a plain on/off; `true` and `false` still mean
    /// exactly what they did. Unset is Automatic.
    pub fn battery_render(&self) -> BatteryRender {
        match self.cfg.get("battery_render") {
            Some(Value::Bool(true)) => BatteryRender::On,
            Some(Value::Bool(false)) => BatteryRender::Off,
            Some(Value::String(s)) if s == "on" => BatteryRender::On,
            Some(Value::String(s)) if s == "off" => BatteryRender::Off,
            _ => BatteryRender::Auto,
        }
    }

    fn number(&self, key: &str, default: f64) -> f64 {
        self.cfg
            .get(key)
            .and_then(|v| v.as_f64())
            .filter(|n| n.is_finite())
            .unwrap_or(default)
    }

    /// Every `--option=value` this configuration implies. An option this
    /// mpv doesn't have is `mpv::Session::start`'s problem, not this
    /// function's — see the module docs.
    pub fn args(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let mut push = |option: &str, value: String| {
            out.push(format!("--{}={}", option, value));
        };

        // ---- Decoding ----
        // "auto" prefers the mature decode paths (VAAPI on AMD/Intel, NVDEC on
        // NVIDIA) over Vulkan video decode, which still produces black frames
        // for some content on Mesa. mpv falls back to software on its own when
        // the named path can't take the codec.
        push(
            "hwdec",
            match self.text("hwdec").as_str() {
                "vaapi" => "vaapi".into(),
                // Decode in hardware, hand the frame over through system
                // memory: skips the dmabuf interop between the decoder and
                // the renderer. Not offered in Settings; here so it can be
                // tried by editing config.json when the interop misbehaves.
                "vaapi-copy" => "vaapi-copy".into(),
                "nvdec" => "nvdec".into(),
                "vulkan" => "vulkan".into(),
                "off" => "no".into(),
                _ => "vaapi,nvdec".to_string(),
            },
        );

        // ---- Track languages ----
        // mpv takes a comma-separated preference list and picks the first track
        // that matches, so "jpn,eng" means "Japanese if it exists, else English".
        let alang = self.text("audio_lang");
        if !alang.is_empty() {
            push("alang", alang);
        }
        let slang = self.text("sub_lang");
        if slang == "off" {
            // Not the same as an empty --slang: this is "never turn subtitles
            // on by itself", which is the setting people actually want when
            // they say they don't use subtitles.
            push("sid", "no".into());
        } else if slang == "forced" {
            // Forced only: signs and the odd line of foreign dialogue, whatever
            // the audio is in. No language is preferred, a track merely flagged
            // default is not taken, and a forced one always is.
            push("sid", "auto".into());
            push("subs-fallback", "no".into());
            push("subs-fallback-forced", "always".into());
        } else if !slang.is_empty() {
            push("slang", slang.clone());
            push("sid", "auto".into());
        }
        // Forced subtitles only: when the audio is already in a preferred
        // language, show nothing but the signs-and-songs track. mpv understands
        // this natively as a third value of subs-with-matching-audio.
        if self.flag("subs_forced_only") && slang != "off" && slang != "forced" {
            push("subs-with-matching-audio", "forced".into());
        }

        // ---- Motion ----
        // 23.976fps film on a 60Hz panel is displayed 3 frames, 2 frames, 3, 2 —
        // the judder everyone sees on pans and nobody can name. Resampling the
        // audio to the display's real refresh rate and interpolating frames onto
        // it removes the cadence. It costs GPU time, so it's opt-in.
        if self.flag("smooth_motion") {
            push("video-sync", "display-resample".into());
            push("interpolation", "yes".into());
            push("tscale", "oversample".into());
        }

        // ---- Power ----
        // Every pass of mpv's default scaler chain runs at the panel's full
        // size — 2880×1920 on a HiDPI laptop — through 16-bit float
        // intermediates. From the couch, bilinear and lanczos are the same
        // picture; at the wall they are not. Opt-in, because on mains power
        // the default chain is the better picture.
        // Automatic is not an option here: it's a profile applied and lifted
        // at runtime (`Player::sync_battery_profile`).
        if self.battery_render() == BatteryRender::On {
            push("scale", "bilinear".into());
            push("cscale", "bilinear".into());
            push("dscale", "bilinear".into());
            push("dither", "no".into());
            push("correct-downscaling", "no".into());
            push("linear-downscaling", "no".into());
            push("sigmoid-upscaling", "no".into());
            push("hdr-compute-peak", "no".into());
            push("fbo-format", "rgba8".into());
        }

        // ---- Subtitle appearance ----
        let size = self.number("sub_font_size", 38.0).clamp(10.0, 120.0);
        if (size - 38.0).abs() > 0.5 {
            push("sub-font-size", format!("{:.0}", size));
        }
        let pos = self.number("sub_pos", 100.0).clamp(0.0, 150.0);
        if (pos - 100.0).abs() > 0.5 {
            push("sub-pos", format!("{:.0}", pos));
        }
        match self.text("sub_bg").as_str() {
            // An opaque strip behind the text — the only thing that stays
            // readable over a bright scene.
            "box" => {
                push("sub-back-color", "#C0000000".into());
                push("sub-border-size", "0".into());
                push("sub-shadow-offset", "0".into());
            }
            "shadow" => {
                push("sub-back-color", "#00000000".into());
                push("sub-border-size", "1.5".into());
                push("sub-shadow-offset", "2".into());
            }
            // "outline" is mpv's own default; nothing to say.
            _ => {}
        }

        // ---- Audio ----
        let device = self.text("audio_device");
        if !device.is_empty() && device != "auto" {
            push("audio-device", device);
        }
        if self.flag("stereo_downmix") {
            push("audio-channels", "stereo".into());
        }
        // Saved from the tune panel: a headset that runs behind the picture
        // runs behind it on every file.
        let audio_delay = self.number("audio_delay", 0.0).clamp(-10.0, 10.0);
        if audio_delay.abs() > 0.0005 {
            push("audio-delay", format!("{:.3}", audio_delay));
        }
        if self.flag("night_mode") {
            // Compress the range so whispered dialogue and an explosion end up
            // within reach of each other. dynaudnorm is a realtime filter;
            // loudnorm (the other obvious choice) needs a two-pass analysis and
            // stalls the start of playback.
            push("af", "lavfi=[dynaudnorm=f=250:g=15:p=0.9:m=6]".into());
        }

        // ---- Picture ----
        for (key, option) in [
            ("pic_brightness", "brightness"),
            ("pic_contrast", "contrast"),
            ("pic_saturation", "saturation"),
            ("pic_gamma", "gamma"),
        ] {
            let v = self.number(key, 0.0).clamp(-100.0, 100.0);
            if v.abs() > 0.5 {
                push(option, format!("{:.0}", v));
            }
        }
        let aspect = self.text("video_aspect");
        if !aspect.is_empty() {
            push("video-aspect-override", aspect);
        }
        let zoom = self.number("video_zoom", 0.0).clamp(-2.0, 2.0);
        if zoom.abs() > 0.001 {
            push("video-zoom", format!("{:.3}", zoom));
        }

        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn prefs(v: Value) -> Prefs {
        Prefs { cfg: v }
    }

    #[test]
    fn subtitles_off_is_not_an_empty_language() {
        let args = prefs(json!({ "sub_lang": "off" })).args();
        assert!(args.iter().any(|a| a == "--sid=no"));
        assert!(!args.iter().any(|a| a.starts_with("--slang")));
    }

    #[test]
    fn forced_only_is_dropped_when_subtitles_are_off() {
        let args =
            prefs(json!({ "sub_lang": "off", "subs_forced_only": true })).args();
        assert!(!args.iter().any(|a| a.contains("subs-with-matching-audio")));
    }

    /// Battery saver is a whole chain of options or none of them: half a
    /// profile is the worst of both.
    #[test]
    fn battery_saver_is_all_or_nothing() {
        let off = prefs(json!({})).args();
        assert!(!off.iter().any(|a| a.starts_with("--scale=") || a.starts_with("--fbo-format=")));
        let on = prefs(json!({ "battery_render": true })).args();
        for want in ["--scale=bilinear", "--dither=no", "--fbo-format=rgba8", "--hdr-compute-peak=no"] {
            assert!(on.iter().any(|a| a == want), "missing {want}");
        }
        assert_eq!(prefs(json!({ "battery_render": "on" })).args(), on);
        // Automatic is a runtime profile, not a startup option.
        assert_eq!(prefs(json!({ "battery_render": "auto" })).args(), off);
        assert_eq!(prefs(json!({})).battery_render(), BatteryRender::Auto);
        assert_eq!(prefs(json!({ "battery_render": false })).battery_render(), BatteryRender::Off);
    }

    /// Always-on and Automatic must draw the same picture: the options pushed
    /// for "on" and the bundled profile Automatic applies are one list.
    #[test]
    fn battery_profile_matches_battery_args() {
        // From the app crate, or from portable-tests one folder below it.
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let conf = std::fs::read_to_string(dir.join("mpv-config/mpv.conf"))
            .or_else(|_| std::fs::read_to_string(dir.join("../mpv-config/mpv.conf")))
            .expect("bundled mpv.conf");
        let header = format!("[{BATTERY_PROFILE}]");
        let body: Vec<String> = conf
            .lines()
            .skip_while(|l| l.trim() != header)
            .skip(1)
            .take_while(|l| !l.trim_start().starts_with('['))
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with("profile-"))
            .map(|l| format!("--{l}"))
            .collect();
        assert!(!body.is_empty(), "no [{BATTERY_PROFILE}] profile in mpv.conf");
        // What "on" adds over the defaults is exactly the battery chain.
        let off = prefs(json!({})).args();
        let mut on: Vec<String> = prefs(json!({ "battery_render": true }))
            .args()
            .into_iter()
            .filter(|a| !off.contains(a))
            .collect();
        let mut body = body;
        on.sort();
        body.sort();
        assert_eq!(on, body);
    }

    /// Defaults must produce no subtitle styling at all, so mpv's own defaults
    /// (and anything in the bundled config) stay in charge.
    #[test]
    fn default_appearance_says_nothing() {
        let args = prefs(json!({})).args();
        assert!(!args.iter().any(|a| a.starts_with("--sub-")));
        assert!(!args.iter().any(|a| a.starts_with("--brightness")));
        assert!(!args.iter().any(|a| a.starts_with("--audio-delay")));
    }

    #[test]
    fn forced_only_is_not_a_language() {
        let args = prefs(json!({ "sub_lang": "forced", "subs_forced_only": true })).args();
        assert!(args.contains(&"--subs-fallback-forced=always".to_string()));
        assert!(args.contains(&"--subs-fallback=no".to_string()));
        assert!(!args.iter().any(|a| a.starts_with("--slang")));
        assert!(!args.iter().any(|a| a.starts_with("--subs-with-matching-audio")));
    }

    #[test]
    fn audio_delay_carries_to_the_next_file() {
        // Regression: 13ea908 saved the tune panel's audio delay to config and
        // applies it to every file from here.
        let args = prefs(json!({ "audio_delay": -0.25 })).args();
        assert!(args.iter().any(|a| a == "--audio-delay=-0.250"), "{args:?}");
    }

    /// The value of `--option=` in `args`, if it is there.
    fn opt(args: &[String], option: &str) -> Option<String> {
        let prefix = format!("--{option}=");
        args.iter().find_map(|a| a.strip_prefix(&prefix).map(str::to_owned))
    }

    fn one(cfg: Value, option: &str) -> Option<String> {
        opt(&prefs(cfg).args(), option)
    }

    #[test]
    fn load_reads_the_saved_config() {
        let _s = crate::test_support::sandbox();
        crate::config::merge(json!({ "hwdec": "off", "audio_lang": "jpn", "battery_render": "on" })).unwrap();
        let p = Prefs::load();
        assert_eq!(p.battery_render(), BatteryRender::On);
        let args = p.args();
        assert_eq!(opt(&args, "hwdec").as_deref(), Some("no"));
        assert_eq!(opt(&args, "alang").as_deref(), Some("jpn"));
    }

    #[test]
    fn hardware_decoding_choices() {
        for (setting, want) in [
            (json!("vaapi"), "vaapi"),
            (json!("vaapi-copy"), "vaapi-copy"),
            (json!("nvdec"), "nvdec"),
            (json!("vulkan"), "vulkan"),
            (json!("off"), "no"),
            (json!(" off "), "no"),
            (json!("auto"), "vaapi,nvdec"),
            (json!("something new"), "vaapi,nvdec"),
            (json!(5), "vaapi,nvdec"),
        ] {
            assert_eq!(one(json!({ "hwdec": setting.clone() }), "hwdec").as_deref(), Some(want), "{setting}");
        }
        // Automatic stays away from Vulkan decode (black frames on Mesa).
        assert_eq!(one(json!({}), "hwdec").as_deref(), Some("vaapi,nvdec"));
    }

    #[test]
    fn track_languages_are_passed_as_mpv_lists() {
        let args = prefs(json!({ "audio_lang": " jpn,eng ", "sub_lang": "eng" })).args();
        assert_eq!(opt(&args, "alang").as_deref(), Some("jpn,eng"));
        assert_eq!(opt(&args, "slang").as_deref(), Some("eng"));
        assert_eq!(opt(&args, "sid").as_deref(), Some("auto"));
        // No preference says nothing at all.
        let none = prefs(json!({ "audio_lang": "", "sub_lang": "  " })).args();
        for o in ["alang", "slang", "sid"] {
            assert_eq!(opt(&none, o), None, "{o}");
        }
    }

    #[test]
    fn forced_only_rides_on_a_language_preference() {
        assert_eq!(
            one(json!({ "sub_lang": "eng", "subs_forced_only": true }), "subs-with-matching-audio").as_deref(),
            Some("forced")
        );
        // With no language set it still applies: mpv's own pick is in charge.
        assert_eq!(
            one(json!({ "subs_forced_only": true }), "subs-with-matching-audio").as_deref(),
            Some("forced")
        );
        assert_eq!(one(json!({ "subs_forced_only": "yes" }), "subs-with-matching-audio"), None);
    }

    #[test]
    fn smooth_motion_is_three_options_together() {
        let args = prefs(json!({ "smooth_motion": true })).args();
        assert_eq!(opt(&args, "video-sync").as_deref(), Some("display-resample"));
        assert_eq!(opt(&args, "interpolation").as_deref(), Some("yes"));
        assert_eq!(opt(&args, "tscale").as_deref(), Some("oversample"));
        let off = prefs(json!({ "smooth_motion": false })).args();
        assert!(["video-sync", "interpolation", "tscale"].iter().all(|o| opt(&off, o).is_none()));
    }

    #[test]
    fn battery_render_reads_old_and_new_forms() {
        for (v, want) in [
            (json!(true), BatteryRender::On),
            (json!("on"), BatteryRender::On),
            (json!(false), BatteryRender::Off),
            (json!("off"), BatteryRender::Off),
            (json!("auto"), BatteryRender::Auto),
            (json!("ON"), BatteryRender::Auto),
            (json!(1), BatteryRender::Auto),
            (Value::Null, BatteryRender::Auto),
        ] {
            assert_eq!(prefs(json!({ "battery_render": v.clone() })).battery_render(), want, "{v}");
        }
        assert_eq!(prefs(json!({ "battery_render": "off" })).args(), prefs(json!({})).args());
    }

    #[test]
    fn subtitle_size_and_position_are_clamped_and_only_sent_when_moved() {
        assert_eq!(one(json!({ "sub_font_size": 38 }), "sub-font-size"), None);
        assert_eq!(one(json!({ "sub_font_size": 38.4 }), "sub-font-size"), None);
        assert_eq!(one(json!({ "sub_font_size": 50 }), "sub-font-size").as_deref(), Some("50"));
        assert_eq!(one(json!({ "sub_font_size": 500 }), "sub-font-size").as_deref(), Some("120"));
        assert_eq!(one(json!({ "sub_font_size": 1 }), "sub-font-size").as_deref(), Some("10"));
        assert_eq!(one(json!({ "sub_font_size": "big" }), "sub-font-size"), None);
        assert_eq!(one(json!({ "sub_pos": 100 }), "sub-pos"), None);
        assert_eq!(one(json!({ "sub_pos": 90 }), "sub-pos").as_deref(), Some("90"));
        assert_eq!(one(json!({ "sub_pos": -20 }), "sub-pos").as_deref(), Some("0"));
        assert_eq!(one(json!({ "sub_pos": 999 }), "sub-pos").as_deref(), Some("150"));
    }

    #[test]
    fn subtitle_backgrounds() {
        let boxed = prefs(json!({ "sub_bg": "box" })).args();
        assert_eq!(opt(&boxed, "sub-back-color").as_deref(), Some("#C0000000"));
        assert_eq!(opt(&boxed, "sub-border-size").as_deref(), Some("0"));
        assert_eq!(opt(&boxed, "sub-shadow-offset").as_deref(), Some("0"));
        let shadow = prefs(json!({ "sub_bg": "shadow" })).args();
        assert_eq!(opt(&shadow, "sub-back-color").as_deref(), Some("#00000000"));
        assert_eq!(opt(&shadow, "sub-border-size").as_deref(), Some("1.5"));
        assert_eq!(opt(&shadow, "sub-shadow-offset").as_deref(), Some("2"));
        // Outline is mpv's default: nothing said.
        assert_eq!(prefs(json!({ "sub_bg": "outline" })).args(), prefs(json!({})).args());
    }

    #[test]
    fn audio_output_options() {
        assert_eq!(one(json!({ "audio_device": "auto" }), "audio-device"), None);
        assert_eq!(one(json!({ "audio_device": "" }), "audio-device"), None);
        assert_eq!(
            one(json!({ "audio_device": "pipewire/alsa_output.usb" }), "audio-device").as_deref(),
            Some("pipewire/alsa_output.usb")
        );
        assert_eq!(one(json!({ "stereo_downmix": true }), "audio-channels").as_deref(), Some("stereo"));
        assert_eq!(one(json!({ "stereo_downmix": false }), "audio-channels"), None);
        assert_eq!(
            one(json!({ "night_mode": true }), "af").as_deref(),
            Some("lavfi=[dynaudnorm=f=250:g=15:p=0.9:m=6]")
        );
        assert_eq!(one(json!({}), "af"), None);
    }

    #[test]
    fn audio_delay_is_clamped_and_tiny_values_are_ignored() {
        assert_eq!(one(json!({ "audio_delay": 30 }), "audio-delay").as_deref(), Some("10.000"));
        assert_eq!(one(json!({ "audio_delay": -30 }), "audio-delay").as_deref(), Some("-10.000"));
        assert_eq!(one(json!({ "audio_delay": 0.0004 }), "audio-delay"), None);
        assert_eq!(one(json!({ "audio_delay": 0.1 }), "audio-delay").as_deref(), Some("0.100"));
    }

    #[test]
    fn picture_adjustments() {
        let args = prefs(json!({
            "pic_brightness": 10,
            "pic_contrast": -250,
            "pic_saturation": 0.2,
            "pic_gamma": 300,
        }))
        .args();
        assert_eq!(opt(&args, "brightness").as_deref(), Some("10"));
        assert_eq!(opt(&args, "contrast").as_deref(), Some("-100"));
        assert_eq!(opt(&args, "saturation"), None, "half a step is no change");
        assert_eq!(opt(&args, "gamma").as_deref(), Some("100"));
    }

    #[test]
    fn aspect_and_zoom() {
        assert_eq!(one(json!({ "video_aspect": "16:9" }), "video-aspect-override").as_deref(), Some("16:9"));
        assert_eq!(one(json!({ "video_aspect": "" }), "video-aspect-override"), None);
        assert_eq!(one(json!({ "video_zoom": 0.25 }), "video-zoom").as_deref(), Some("0.250"));
        assert_eq!(one(json!({ "video_zoom": 9 }), "video-zoom").as_deref(), Some("2.000"));
        assert_eq!(one(json!({ "video_zoom": -9 }), "video-zoom").as_deref(), Some("-2.000"));
        assert_eq!(one(json!({ "video_zoom": 0.0005 }), "video-zoom"), None);
    }

    #[test]
    fn every_argument_is_an_mpv_option() {
        let args = prefs(json!({
            "hwdec": "vaapi", "audio_lang": "eng", "sub_lang": "eng", "subs_forced_only": true,
            "smooth_motion": true, "battery_render": true, "sub_font_size": 50, "sub_pos": 90,
            "sub_bg": "box", "audio_device": "x", "stereo_downmix": true, "audio_delay": 1,
            "night_mode": true, "pic_brightness": 5, "video_aspect": "4:3", "video_zoom": 1,
        }))
        .args();
        assert!(args.iter().all(|a| a.starts_with("--") && a.contains('=')), "{args:?}");
        let mut names: Vec<&str> = args.iter().map(|a| a.split('=').next().unwrap()).collect();
        let n = names.len();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), n, "an option was given twice: {args:?}");
    }
}
