//! 8-line feedback delay network reverb.
//!
//! Topology (the one used by most modern algorithmic reverbs): pre-delay →
//! four input allpasses → eight prime-numbered delay lines → per-line damping →
//! an orthogonal 8×8 Householder feedback matrix → two decorrelated stereo taps.
//!
//! Why not Freeverb: its eight parallel combs ring metallically and its "size"
//! is only a feedback change. Why not Dattorro: no honest size control, and the
//! signed taps are easy to get subtly wrong. The FDN costs about the same CPU
//! and gives a real room-size knob plus an exact RT60.
//!
//! Algorithms are public-domain math (Householder matrices, Schroeder allpass,
//! Jot/Smith FDN design). No GPL code involved.

use super::util::flush_denormal;
use serde::{Deserialize, Serialize};
use std::f32::consts::TAU;

const N: usize = 8;
/// Prime-ish line lengths at 48 kHz (31–86 ms), coprime to avoid coincident
/// echoes. Scaled by the size knob.
const BASE_LEN: [usize; N] = [1499, 1823, 2099, 2399, 2741, 3137, 3593, 4127];
/// Input diffusion (Dattorro allpass lengths, scaled from 29.761 kHz to 48 kHz).
const AP_LEN: [usize; 4] = [229, 173, 611, 447];
const AP_GAIN: [f32; 4] = [0.75, 0.75, 0.625, 0.625];
/// Zero-sum injection: never excite the all-ones mode (it would ring forever).
const INJECTION: [f32; N] = [1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0];
/// Two orthogonal tap patterns → decorrelated left/right tails.
const TAP_L: [f32; N] = [1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0];
const TAP_R: [f32; N] = [1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0];
const MOD_DEPTH: f32 = 4.0;
const MAX_PREDELAY_SECONDS: f32 = 0.2;

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReverbParams {
    pub enabled: bool,
    /// Room size, 0..1. Scales the delay lengths (small club → hall).
    pub size: f32,
    /// Decay, 0..1. Maps to RT60.
    pub decay: f32,
    /// Tone, 0..1. 0 = dark tail, 1 = bright.
    pub tone: f32,
    pub predelay_ms: f32,
    /// Wet return level, 0..1 (this is a send bus, so it is wet only).
    pub return_level: f32,
}

impl Default for ReverbParams {
    fn default() -> Self {
        Self {
            enabled: false,
            size: 0.62,
            decay: 0.55,
            tone: 0.55,
            predelay_ms: 18.0,
            return_level: 0.45,
        }
    }
}

impl ReverbParams {
    pub fn sanitized(mut self) -> Self {
        self.size = self.size.clamp(0.0, 1.0);
        self.decay = self.decay.clamp(0.0, 1.0);
        self.tone = self.tone.clamp(0.0, 1.0);
        self.predelay_ms = self.predelay_ms.clamp(0.0, MAX_PREDELAY_SECONDS * 1000.0);
        self.return_level = self.return_level.clamp(0.0, 1.0);
        self
    }

    /// Exact RT60 in seconds, from the decay knob.
    pub fn rt60_seconds(&self) -> f32 {
        0.3 * 60.0_f32.powf(self.decay)
    }

    /// Room scale applied to the line lengths.
    pub fn size_scale(&self) -> f32 {
        0.25 * 4.0_f32.powf(self.size)
    }
}

struct Line {
    buffer: Vec<f32>,
    length: usize,
    write: usize,
}

impl Line {
    fn new(max_len: usize) -> Self {
        Self {
            buffer: vec![0.0; max_len.max(2)],
            length: 1,
            write: 0,
        }
    }

    fn configure(&mut self, length: usize) {
        let length = length.clamp(2, self.buffer.len());
        if length != self.length {
            self.buffer.iter_mut().for_each(|s| *s = 0.0);
            self.write = 0;
            self.length = length;
        }
    }

    #[inline]
    fn read(&self, delay: f32) -> f32 {
        let d = delay.clamp(1.0, (self.length - 2) as f32);
        let whole = d as usize;
        let frac = d - whole as f32;
        let i0 = (self.write + self.length - whole) % self.length;
        let i1 = (self.write + self.length - whole - 1) % self.length;
        self.buffer[i0] * (1.0 - frac) + self.buffer[i1] * frac
    }

    #[inline]
    fn write(&mut self, x: f32) {
        self.buffer[self.write] = flush_denormal(x);
        self.write += 1;
        if self.write >= self.length {
            self.write = 0;
        }
    }
}

struct Allpass {
    buffer: Vec<f32>,
    index: usize,
    length: usize,
    gain: f32,
}

impl Allpass {
    fn new(max_len: usize, gain: f32) -> Self {
        Self {
            buffer: vec![0.0; max_len.max(2)],
            index: 0,
            length: 1,
            gain,
        }
    }

    fn configure(&mut self, length: usize) {
        let length = length.clamp(2, self.buffer.len());
        if length != self.length {
            self.buffer.iter_mut().for_each(|s| *s = 0.0);
            self.index = 0;
            self.length = length;
        }
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        let delayed = self.buffer[self.index];
        let output = delayed - self.gain * input;
        self.buffer[self.index] = flush_denormal(input + self.gain * output);
        self.index += 1;
        if self.index >= self.length {
            self.index = 0;
        }
        output
    }
}

pub struct Reverb {
    lines: Vec<Line>,
    allpasses: Vec<Allpass>,
    predelay: Vec<f32>,
    predelay_write: usize,
    predelay_length: usize,
    damping: [f32; N],
    gains: [f32; N],
    phases: [f32; N],
    phase_inc: [f32; N],
    length: [usize; N],
    damp_coeff: f32,
    input_gain: f32,
    params: ReverbParams,
    sample_rate: f32,
}

impl Reverb {
    pub fn new(sample_rate: f32, params: ReverbParams) -> Self {
        let params = params.sanitized();
        let max_len = (BASE_LEN[N - 1] as f32 * sample_rate / 48_000.0 * 1.1) as usize + 16;
        let max_predelay = (MAX_PREDELAY_SECONDS * sample_rate) as usize + 4;
        let mut reverb = Self {
            lines: (0..N).map(|_| Line::new(max_len)).collect(),
            allpasses: AP_LEN
                .iter()
                .zip(AP_GAIN)
                .map(|(&len, gain)| {
                    Allpass::new((len as f32 * sample_rate / 48_000.0 * 1.1) as usize + 4, gain)
                })
                .collect(),
            predelay: vec![0.0; max_predelay],
            predelay_write: 0,
            predelay_length: 1,
            damping: [0.0; N],
            gains: [0.0; N],
            phases: [0.0; N],
            phase_inc: [0.0; N],
            length: [1; N],
            damp_coeff: 1.0,
            input_gain: 0.1,
            params,
            sample_rate,
        };
        // Each line modulates at a different slow rate (0.31–1.37 Hz).
        for (i, phase_inc) in reverb.phase_inc.iter_mut().enumerate() {
            *phase_inc = TAU * (0.31 + 0.15 * i as f32) / sample_rate;
            reverb.phases[i] = (i as f32) * 0.7;
        }
        reverb.update(sample_rate, params);
        reverb
    }

    pub fn update(&mut self, sample_rate: f32, params: ReverbParams) {
        self.sample_rate = sample_rate;
        self.params = params.sanitized();
        let p = self.params;
        let scale = p.size_scale() * sample_rate / 48_000.0;
        let rt60 = p.rt60_seconds();

        for i in 0..N {
            let len = (BASE_LEN[i] as f32 * scale).round() as usize;
            self.length[i] = len.max(8);
            self.lines[i].configure(self.length[i]);
            // Exact RT60: amplitude falls 60 dB over `rt60` seconds.
            let loop_seconds = self.length[i] as f32 / sample_rate;
            self.gains[i] = 10.0_f32.powf(-3.0 * loop_seconds / rt60);
        }

        for (i, ap) in self.allpasses.iter_mut().enumerate() {
            ap.configure((AP_LEN[i] as f32 * scale * 1.15).round() as usize);
        }

        let fc = 500.0 * 40.0_f32.powf(p.tone);
        self.damp_coeff = 1.0 - (-TAU * fc / sample_rate).exp();
        self.predelay_length = ((p.predelay_ms * 0.001 * sample_rate) as usize)
            .clamp(1, self.predelay.len());

        // Compensate the network's 1/(1−g) buildup so the send stays level
        // across decay settings.
        let mean_gain = self.gains.iter().sum::<f32>() / N as f32;
        self.input_gain = (0.5 * (1.0 - mean_gain)).clamp(0.004, 0.08);
    }

    /// Wet-only output. The caller sums `return_level` inside this function.
    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.params.enabled || self.params.return_level <= 0.0001 {
            return (0.0, 0.0);
        }

        // Pre-delay
        let delayed = self.predelay[self.predelay_write];
        self.predelay[self.predelay_write] = 0.5 * (l + r);
        self.predelay_write += 1;
        if self.predelay_write >= self.predelay_length {
            self.predelay_write = 0;
        }

        let mut x = delayed;
        for ap in self.allpasses.iter_mut() {
            x = ap.process(x);
        }
        x *= self.input_gain;

        let mut s = [0.0_f32; N];
        for i in 0..N {
            self.phases[i] += self.phase_inc[i];
            if self.phases[i] >= TAU {
                self.phases[i] -= TAU;
            }
            let delay = self.length[i] as f32 + MOD_DEPTH * self.phases[i].sin();
            let y = self.lines[i].read(delay);
            self.damping[i] += self.damp_coeff * (y - self.damping[i]);
            s[i] = flush_denormal(self.damping[i] * self.gains[i]);
        }

        // Householder: y_i = s_i − (2/N)·Σs
        let sum: f32 = s.iter().sum();
        for i in 0..N {
            let feedback = s[i] - 0.25 * sum;
            self.lines[i].write(x * INJECTION[i] + feedback);
        }

        let mut wet_l = 0.0;
        let mut wet_r = 0.0;
        for i in 0..N {
            wet_l += TAP_L[i] * self.damping[i];
            wet_r += TAP_R[i] * self.damping[i];
        }
        let norm = 1.0 / (N as f32).sqrt();
        let level = self.params.return_level;
        (wet_l * norm * level, wet_r * norm * level)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> ReverbParams {
        ReverbParams {
            enabled: true,
            return_level: 1.0,
            ..ReverbParams::default()
        }
    }

    #[test]
    fn impulse_produces_a_decaying_tail() {
        let mut r = Reverb::new(48_000.0, params());
        let mut early = 0.0_f32;
        let mut late = 0.0_f32;
        for i in 0..96_000 {
            let (l, rr) = r.process(if i == 0 { 1.0 } else { 0.0 }, if i == 0 { 1.0 } else { 0.0 });
            let e = l * l + rr * rr;
            if (1_000..20_000).contains(&i) {
                early += e;
            }
            if (60_000..80_000).contains(&i) {
                late += e;
            }
            assert!(l.is_finite() && rr.is_finite());
        }
        assert!(early > 0.0, "no tail");
        assert!(late < early, "tail is not decaying");
    }

    #[test]
    fn disabled_reverb_is_silent_and_free() {
        let mut r = Reverb::new(48_000.0, ReverbParams::default());
        for i in 0..1_000 {
            assert_eq!(r.process(i as f32 * 0.1, 0.0), (0.0, 0.0));
        }
    }

    #[test]
    fn wet_output_stays_bounded_at_extreme_decay() {
        let mut r = Reverb::new(48_000.0, ReverbParams {
            enabled: true,
            decay: 1.0,
            return_level: 1.0,
            ..ReverbParams::default()
        });
        let mut peak = 0.0_f32;
        for i in 0..480_000 {
            let x = if i % 4800 == 0 { 0.8 } else { 0.0 };
            let (l, rr) = r.process(x, x);
            peak = peak.max(l.abs()).max(rr.abs());
        }
        assert!(peak.is_finite() && peak < 4.0, "peak {peak}");
    }

    #[test]
    fn stereo_output_is_decorrelated() {
        let mut r = Reverb::new(48_000.0, params());
        let (mut sl, mut sr, mut slr) = (0.0_f32, 0.0_f32, 0.0_f32);
        for i in 0..96_000 {
            let x = if i % 1000 == 0 { 0.7 } else { 0.0 };
            let (l, rr) = r.process(x, x);
            sl += l * l;
            sr += rr * rr;
            slr += l * rr;
        }
        let corr = slr / (sl.sqrt() * sr.sqrt()).max(1e-9);
        assert!(corr < 0.9, "tail is nearly mono: corr {corr}");
    }

    #[test]
    fn rt60_mapping_is_sane() {
        assert!((ReverbParams { decay: 0.0, ..Default::default() }.rt60_seconds() - 0.3).abs() < 1e-3);
        assert!(ReverbParams { decay: 1.0, ..Default::default() }.rt60_seconds() > 10.0);
    }
}
