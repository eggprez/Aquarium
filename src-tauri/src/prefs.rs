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
        } else if !slang.is_empty() {
            push("slang", slang.clone());
            push("sid", "auto".into());
        }
        // Forced subtitles only: when the audio is already in a preferred
        // language, show nothing but the signs-and-songs track. mpv understands
        // this natively as a third value of subs-with-matching-audio.
        if self.flag("subs_forced_only") && slang != "off" {
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
        if self.flag("battery_render") {
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
    }

    /// Defaults must produce no subtitle styling at all, so mpv's own defaults
    /// (and anything in the bundled config) stay in charge.
    #[test]
    fn default_appearance_says_nothing() {
        let args = prefs(json!({})).args();
        assert!(!args.iter().any(|a| a.starts_with("--sub-")));
        assert!(!args.iter().any(|a| a.starts_with("--brightness")));
    }
}
