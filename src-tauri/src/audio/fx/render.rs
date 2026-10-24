//! Offline mixdown: track chains → stereo bus → master chain.
//!
//! Rendering is deterministic and allocation-free inside the loop, so the same
//! code path can later run in a real-time monitor thread.

use super::compressor::Compressor;
use super::delay::StereoDelay;
use super::eq::ChannelEq;
use super::limiter::Limiter;
use super::reverb::Reverb;
use super::util::lin_to_db;
use super::widener::Widener;
use super::{CompParams, EqParams, FxSettings, FxStats};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackMix {
    /// Fader position, 0..1.5 (unity at 1.0).
    pub level: f32,
    /// −1 hard left … 0 centre … +1 hard right.
    pub pan: f32,
    pub muted: bool,
    /// Post-fader send into the reverb bus, 0..1.
    pub send_reverb: f32,
    /// Post-fader send into the delay bus, 0..1.
    pub send_delay: f32,
    pub eq: EqParams,
    pub comp: CompParams,
}

impl Default for TrackMix {
    fn default() -> Self {
        Self {
            level: 0.8,
            pan: 0.0,
            muted: false,
            send_reverb: 0.0,
            send_delay: 0.0,
            eq: EqParams::default(),
            comp: CompParams::default(),
        }
    }
}

impl TrackMix {
    pub fn sanitized(mut self) -> Self {
        self.level = self.level.clamp(0.0, 1.5);
        self.pan = self.pan.clamp(-1.0, 1.0);
        self.send_reverb = self.send_reverb.clamp(0.0, 1.0);
        self.send_delay = self.send_delay.clamp(0.0, 1.0);
        self
    }

    /// Constant-power pan gains (centre = −3 dB per side).
    pub fn pan_gains(&self) -> (f32, f32) {
        if self.muted {
            return (0.0, 0.0);
        }
        let angle = (self.pan + 1.0) * std::f32::consts::FRAC_PI_4;
        (angle.cos() * self.level, angle.sin() * self.level)
    }
}

#[derive(Debug)]
pub struct RenderOutput {
    /// Interleaved stereo, 2 channels.
    pub samples: Vec<f32>,
    pub frames: usize,
    pub peak_db: f32,
    pub stats: FxStats,
}

impl RenderOutput {
    pub fn duration_seconds(&self, sample_rate: f32) -> f32 {
        self.frames as f32 / sample_rate.max(1.0)
    }
}

const METER_HZ: f32 = 20.0;

/// Mix `tracks` (mono, 32-bit float, one vec per track) through the full chain.
pub fn render_mix(track_audio: &[Vec<f32>], settings: &FxSettings, sample_rate: f32) -> RenderOutput {
    let max_len = track_audio.iter().map(|t| t.len()).max().unwrap_or(0);
    let active_sends = settings
        .tracks
        .iter()
        .any(|t| t.send_reverb > 0.001 || t.send_delay > 0.001);
    let tail_seconds = if active_sends && (settings.reverb.enabled || settings.delay.enabled) {
        2.0 + if settings.reverb.enabled {
            settings.reverb.rt60_seconds().min(5.0)
        } else {
            0.0
        }
    } else {
        0.0
    };
    let tail_frames = (tail_seconds * sample_rate) as usize;
    let total = max_len + tail_frames;

    let tracks: Vec<TrackMix> = (0..track_audio.len())
        .map(|i| {
            settings
                .tracks
                .get(i)
                .cloned()
                .unwrap_or_default()
                .sanitized()
        })
        .collect();

    let mut eqs: Vec<ChannelEq> = tracks
        .iter()
        .map(|t| ChannelEq::new(sample_rate, t.eq))
        .collect();
    let mut comps: Vec<Compressor> = tracks
        .iter()
        .map(|t| Compressor::new(sample_rate, t.comp))
        .collect();
    let mut reverb = Reverb::new(sample_rate, settings.reverb);
    let mut delay = StereoDelay::new(sample_rate, settings.delay);
    let mut master_comp = Compressor::new(sample_rate, settings.master_comp);
    let mut widener = Widener::new(sample_rate, settings.width);
    let mut limiter = Limiter::new(sample_rate, settings.limiter);

    let meter_interval = (sample_rate / METER_HZ).max(1.0) as usize;
    let mut track_gr_timeline: Vec<Vec<f32>> = vec![Vec::new(); tracks.len()];
    let mut master_gr_timeline: Vec<f32> = Vec::new();
    let mut limiter_gr_timeline: Vec<f32> = Vec::new();

    let mut samples: Vec<f32> = Vec::with_capacity(total * 2);
    let mut peak = 0.0_f32;

    let mut meter_acc = 0usize;
    for frame in 0..total {
        let mut bus_l = 0.0_f32;
        let mut bus_r = 0.0_f32;
        let mut send_rev_l = 0.0_f32;
        let mut send_rev_r = 0.0_f32;
        let mut send_dly_l = 0.0_f32;
        let mut send_dly_r = 0.0_f32;

        for (i, track) in tracks.iter().enumerate() {
            let raw = track_audio
                .get(i)
                .and_then(|audio| audio.get(frame))
                .copied()
                .unwrap_or(0.0);
            let (mut l, mut r) = eqs[i].process(raw, raw);
            (l, r) = comps[i].process(l, r);
            let (gl, gr) = track.pan_gains();
            let out_l = l * gl;
            let out_r = r * gr;
            bus_l += out_l;
            bus_r += out_r;
            send_rev_l += out_l * track.send_reverb;
            send_rev_r += out_r * track.send_reverb;
            send_dly_l += out_l * track.send_delay;
            send_dly_r += out_r * track.send_delay;
        }

        let (rev_l, rev_r) = reverb.process(send_rev_l, send_rev_r);
        let (dly_l, dly_r) = delay.process(send_dly_l, send_dly_r);

        let (mut l, mut r) = (bus_l + rev_l + dly_l, bus_r + rev_r + dly_r);
        (l, r) = master_comp.process(l, r);
        (l, r) = widener.process(l, r);
        (l, r) = limiter.process(l, r);

        peak = peak.max(l.abs()).max(r.abs());
        samples.push(l);
        samples.push(r);

        meter_acc += 1;
        if meter_acc >= meter_interval {
            meter_acc = 0;
            for (i, comp) in comps.iter().enumerate() {
                track_gr_timeline[i].push(comp.instantaneous_reduction_db());
            }
            master_gr_timeline.push(master_comp.instantaneous_reduction_db());
            limiter_gr_timeline.push(limiter.gain_reduction_db());
        }
    }

    let stats = FxStats {
        track_gr: comps.iter().map(|c| c.gain_reduction_db()).collect(),
        master_gr: master_comp.gain_reduction_db(),
        limiter_gr: limiter.gain_reduction_db(),
        track_gr_timeline,
        master_gr_timeline,
        limiter_gr_timeline,
    };

    RenderOutput {
        samples,
        frames: total,
        peak_db: lin_to_db(peak).max(-120.0),
        stats,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FS: f32 = 48_000.0;

    fn tone(freq: f32, seconds: f32, amp: f32) -> Vec<f32> {
        (0..(seconds * FS) as usize)
            .map(|i| (i as f32 * freq * std::f32::consts::TAU / FS).sin() * amp)
            .collect()
    }

    fn settings(tracks: usize) -> FxSettings {
        FxSettings {
            tracks: (0..tracks)
                .map(|_| TrackMix {
                    comp: CompParams {
                        enabled: false,
                        ..CompParams::default()
                    },
                    ..TrackMix::default()
                })
                .collect(),
            ..FxSettings::default()
        }
    }

    #[test]
    fn dry_render_preserves_the_source() {
        let src = tone(440.0, 0.2, 0.5);
        let out = render_mix(&[src.clone()], &settings(1), FS);
        // Limiter adds latency and applies a −0.3 dB ceiling.
        assert_eq!(out.samples.len(), out.frames * 2);
        let peak = out.samples.iter().fold(0.0_f32, |a, s| a.max(s.abs()));
        let expected = 0.5 * std::f32::consts::FRAC_1_SQRT_2 * 0.8;
        assert!((peak - expected).abs() < 0.02, "peak {peak} expected {expected}");
        assert!(out.stats.track_gr[0] > -0.01);
    }

    #[test]
    fn mute_silences_a_track() {
        let src = tone(440.0, 0.1, 0.5);
        let mut s = settings(1);
        s.tracks[0].muted = true;
        let out = render_mix(&[src], &s, FS);
        assert!(out.peak_db < -100.0);
    }

    #[test]
    fn sends_extend_the_render_with_a_tail() {
        let src = tone(440.0, 0.2, 0.4);
        let mut s = settings(1);
        s.tracks[0].send_reverb = 0.8;
        s.reverb.enabled = true;
        s.reverb.return_level = 0.8;
        let out = render_mix(&[src.clone()], &s, FS);
        assert!(out.frames > src.len(), "no tail frames");
        assert!(out.stats.track_gr_timeline[0].len() > 10);
    }

    #[test]
    fn master_limiter_holds_the_ceiling() {
        let src = tone(220.0, 1.0, 0.9);
        let mut s = settings(4);
        for t in s.tracks.iter_mut() {
            t.level = 1.0;
        }
        let out = render_mix(&[src.clone(), src.clone(), src.clone(), src], &s, FS);
        let ceiling = 10.0_f32.powf(s.limiter.ceiling_db / 20.0);
        assert!(out.peak_db <= 20.0 * ceiling.log10() + 0.01, "peak {}", out.peak_db);
        assert!(out.stats.limiter_gr < -3.0, "limiter barely worked: {}", out.stats.limiter_gr);
    }

    #[test]
    fn hand_les_missing_tracks_safely() {
        let out = render_mix(&[], &settings(0), FS);
        assert_eq!(out.frames, 0);
        assert!(out.samples.is_empty());
    }
}
