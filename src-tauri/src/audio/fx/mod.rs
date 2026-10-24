//! Native effects rack.
//!
//! Everything is hand-written DSP — no VST, no plugin host, no GPL crates.
//! Per track: EQ → compressor → fader/pan, with post-fader sends to the
//! reverb and delay buses. On the master bus: compressor → widener → limiter.
//!
//! All filters are real-time safe: buffers are allocated when the chain is
//! constructed, never inside `process`.

pub mod biquad;
pub mod compressor;
pub mod delay;
pub mod eq;
pub mod limiter;
pub mod reverb;
pub mod render;
pub mod util;
pub mod widener;

pub use compressor::CompParams;
pub use delay::DelayParams;
pub use eq::EqParams;
pub use limiter::LimiterParams;
pub use render::TrackMix;
pub use reverb::ReverbParams;
pub use widener::WidthParams;

use serde::{Deserialize, Serialize};

/// Complete effects settings for a mixdown, sent from the UI.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FxSettings {
    #[serde(default)]
    pub tracks: Vec<TrackMix>,
    #[serde(default)]
    pub master_comp: CompParams,
    #[serde(default)]
    pub reverb: ReverbParams,
    #[serde(default)]
    pub delay: DelayParams,
    #[serde(default)]
    pub width: WidthParams,
    #[serde(default)]
    pub limiter: LimiterParams,
}

impl Default for FxSettings {
    fn default() -> Self {
        Self {
            tracks: Vec::new(),
            master_comp: CompParams {
                enabled: false,
                threshold_db: -14.0,
                ratio: 2.5,
                attack_ms: 20.0,
                release_ms: 250.0,
                knee_db: 10.0,
                mix: 1.0,
                ..CompParams::default()
            },
            reverb: ReverbParams::default(),
            delay: DelayParams::default(),
            width: WidthParams::default(),
            limiter: LimiterParams::default(),
        }
    }
}

/// Render statistics for the UI: how hard each stage worked.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FxStats {
    /// Worst compressor reduction per track, dB (≤ 0).
    pub track_gr: Vec<f32>,
    /// Worst master compressor reduction, dB (≤ 0).
    pub master_gr: f32,
    /// Worst limiter reduction, dB (≤ 0).
    pub limiter_gr: f32,
    /// Compressor reduction per track over time, 20 points/second (dB ≤ 0).
    pub track_gr_timeline: Vec<Vec<f32>>,
    /// Master compressor reduction over time.
    pub master_gr_timeline: Vec<f32>,
    /// Limiter reduction over time.
    pub limiter_gr_timeline: Vec<f32>,
}
