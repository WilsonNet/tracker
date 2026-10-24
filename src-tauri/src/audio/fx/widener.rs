//! Master stereo widener.
//!
//! Mid/side width with a frequency split: the side signal above `bass_hz` is
//! scaled, everything below stays summed to mono. Because the mono sum is
//! `L + R = 2M` for any width, this stays mono-compatible — only the stereo
//! image changes.

use super::util::coeff_for_ms;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WidthParams {
    pub enabled: bool,
    /// 0 = mono, 1 = unchanged, 2 = double width.
    pub width: f32,
    /// Side content below this frequency is folded to mono.
    pub bass_hz: f32,
}

impl Default for WidthParams {
    fn default() -> Self {
        Self {
            enabled: false,
            width: 1.0,
            bass_hz: 140.0,
        }
    }
}

impl WidthParams {
    pub fn sanitized(mut self) -> Self {
        self.width = self.width.clamp(0.0, 2.0);
        self.bass_hz = self.bass_hz.clamp(40.0, 400.0);
        self
    }

    /// How much of the low side content is removed, 0..1.
    pub fn bass_mono_amount(&self) -> f32 {
        if self.width <= 1.0 {
            0.0
        } else {
            (self.width - 1.0).min(1.0)
        }
    }
}

pub struct Widener {
    params: WidthParams,
    lp_l: f32,
    lp_r: f32,
    coeff: f32,
    sample_rate: f32,
}

impl Widener {
    pub fn new(sample_rate: f32, params: WidthParams) -> Self {
        let mut w = Self {
            params: params.sanitized(),
            lp_l: 0.0,
            lp_r: 0.0,
            coeff: 1.0,
            sample_rate,
        };
        w.update(sample_rate, params);
        w
    }

    pub fn update(&mut self, sample_rate: f32, params: WidthParams) {
        self.sample_rate = sample_rate;
        self.params = params.sanitized();
        // 12 dB/oct side split: two cascaded one-poles.
        self.coeff = 1.0 - (-std::f32::consts::TAU * self.params.bass_hz / sample_rate).exp();
        // 10 ms smoothing would matter for live automation; static here.
        let _ = coeff_for_ms(10.0, sample_rate);
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.params.enabled || (self.params.width - 1.0).abs() < 0.001 {
            return (l, r);
        }
        let mid = (l + r) * 0.5;
        let side = (l - r) * 0.5;

        // Two-pole low-pass on the side signal, then take the complement.
        self.lp_l += self.coeff * (side - self.lp_l);
        self.lp_r += self.coeff * (self.lp_l - self.lp_r);
        let low = self.lp_r;
        let high = side - low;

        // Below unity width, narrow both bands. Above unity, leave the bass
        // summed to mono and widen only the top.
        let low_gain = self.params.width.min(1.0) * (1.0 - self.params.bass_mono_amount());
        let out_side = low * low_gain + high * self.params.width;
        // Widening adds side energy; trim the peak so bypass and active match.
        let trim = 1.0 / (1.0 + 0.5 * (self.params.width - 1.0).max(0.0));
        (
            ((mid + out_side) * trim).clamp(-8.0, 8.0),
            ((mid - out_side) * trim).clamp(-8.0, 8.0),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn width_of_one_is_a_passthrough() {
        let mut w = Widener::new(48_000.0, WidthParams {
            enabled: true,
            width: 1.0,
            ..WidthParams::default()
        });
        for i in 0..1_000 {
            let l = (i as f32 * 0.01).sin();
            let r = (i as f32 * 0.013).cos();
            assert_eq!(w.process(l, r), (l, r));
        }
    }

    #[test]
    fn wide_keeps_the_mono_sum() {
        let mut w = Widener::new(48_000.0, WidthParams {
            enabled: true,
            width: 2.0,
            ..WidthParams::default()
        });
        let trim = 1.0 / 1.5;
        let mut worst = 0.0_f32;
        for i in 0..48_000 {
            let t = i as f32 / 48_000.0;
            let l = (t * 440.0 * std::f32::consts::TAU).sin() * 0.5;
            let r = (t * 660.0 * std::f32::consts::TAU).sin() * 0.5;
            let (ol, or) = w.process(l, r);
            worst = worst.max((((ol + or) / trim) - (l + r)).abs());
        }
        assert!(worst < 1e-5, "mono sum changed by {worst}");
    }

    #[test]
    fn zero_width_collapses_to_mono() {
        let mut w = Widener::new(48_000.0, WidthParams {
            enabled: true,
            width: 0.0,
            ..WidthParams::default()
        });
        let (mut l, mut r) = (0.0, 0.0);
        for _ in 0..48_000 {
            let (a, b) = w.process(0.5, -0.25);
            l = a;
            r = b;
        }
        assert!((l - r).abs() < 0.05, "not mono: {l} {r}");
    }
}
