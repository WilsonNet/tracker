//! Feed-forward stereo-linked compressor with soft knee and auto makeup.
//!
//! Detector: peak (max of |L|, |R|) with a one-pole attack/release envelope.
//! Gain computer: soft-knee static curve in dB, then a smoothed gain applied to
//! both channels so the stereo image never shifts.

use super::util::{coeff_for_ms, db_to_lin, lin_to_db};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompParams {
    pub enabled: bool,
    pub threshold_db: f32,
    pub ratio: f32,
    pub attack_ms: f32,
    pub release_ms: f32,
    pub knee_db: f32,
    pub makeup_db: f32,
    pub mix: f32,
    pub auto_makeup: bool,
}

impl Default for CompParams {
    fn default() -> Self {
        Self {
            enabled: true,
            threshold_db: -18.0,
            ratio: 3.0,
            attack_ms: 12.0,
            release_ms: 180.0,
            knee_db: 8.0,
            makeup_db: 0.0,
            mix: 1.0,
            auto_makeup: true,
        }
    }
}

impl CompParams {
    pub fn sanitized(mut self) -> Self {
        self.threshold_db = self.threshold_db.clamp(-60.0, 0.0);
        self.ratio = self.ratio.clamp(1.0, 20.0);
        self.attack_ms = self.attack_ms.clamp(0.1, 300.0);
        self.release_ms = self.release_ms.clamp(5.0, 2000.0);
        self.knee_db = self.knee_db.clamp(0.0, 24.0);
        self.makeup_db = self.makeup_db.clamp(-12.0, 24.0);
        self.mix = self.mix.clamp(0.0, 1.0);
        self
    }

    /// Makeup that restores roughly the loudness the compressor removes.
    /// `0.6 × (−threshold) × (1 − 1/ratio)` — the textbook "unity at 0 dBFS"
    /// value is too hot on real program material.
    pub fn auto_makeup_db(&self) -> f32 {
        if self.ratio <= 1.0001 {
            return 0.0;
        }
        (0.6 * -self.threshold_db * (1.0 - 1.0 / self.ratio)).clamp(0.0, 24.0)
    }

    pub fn effective_makeup_db(&self) -> f32 {
        if self.auto_makeup {
            self.auto_makeup_db()
        } else {
            self.makeup_db
        }
    }

    /// Static transfer curve: input dB → output dB, before makeup.
    pub fn transfer_db(&self, input_db: f32) -> f32 {
        let over = input_db - self.threshold_db;
        let slope = 1.0 - 1.0 / self.ratio.max(1.0);
        let knee = self.knee_db;
        let reduction = if knee <= 0.0 {
            over.max(0.0) * slope
        } else if over <= -knee * 0.5 {
            0.0
        } else if over >= knee * 0.5 {
            over * slope
        } else {
            let x = over + knee * 0.5;
            slope * x * x / (2.0 * knee)
        };
        input_db - reduction
    }
}

pub struct Compressor {
    sample_rate: f32,
    params: CompParams,
    attack_coeff: f32,
    release_coeff: f32,
    makeup_lin: f32,
    /// Release-smoothed gain reduction (dB, ≤ 0).
    y1: f32,
    /// Attack-smoothed gain reduction applied to the audio (dB, ≤ 0).
    gain_db: f32,
    /// Worst-case reduction seen since `reset_meter`.
    min_gain_db: f32,
}

impl Compressor {
    pub fn new(sample_rate: f32, params: CompParams) -> Self {
        let params = params.sanitized();
        let mut c = Self {
            sample_rate,
            params,
            attack_coeff: 0.0,
            release_coeff: 0.0,
            makeup_lin: 1.0,
            y1: 0.0,
            gain_db: 0.0,
            min_gain_db: 0.0,
        };
        c.update(sample_rate, params);
        c
    }

    pub fn update(&mut self, sample_rate: f32, params: CompParams) {
        self.sample_rate = sample_rate;
        self.params = params.sanitized();
        self.attack_coeff = coeff_for_ms(self.params.attack_ms, sample_rate);
        self.release_coeff = coeff_for_ms(self.params.release_ms, sample_rate);
        self.makeup_lin = db_to_lin(self.params.effective_makeup_db());
    }

    pub fn gain_reduction_db(&self) -> f32 {
        self.min_gain_db
    }

    pub fn instantaneous_reduction_db(&self) -> f32 {
        self.gain_db
    }

    #[inline]
    fn target_reduction_db(&self, input_db: f32) -> f32 {
        self.params.transfer_db(input_db) - input_db
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.params.enabled || self.params.ratio <= 1.0001 {
            return (l, r);
        }
        let detector = l.abs().max(r.abs());
        let input_db = lin_to_db(detector);
        let target = self.target_reduction_db(input_db).min(0.0);

        // Smooth decoupled detector (Giannoulis/Massberg/Reiss 2012, eq. 17),
        // applied to the gain signal so the knee stays variable and clicks-free:
        // release smoothing with instant attack, then attack smoothing.
        self.y1 = target.min(
            self.release_coeff * self.y1 + (1.0 - self.release_coeff) * target,
        );
        self.gain_db = self.attack_coeff * self.gain_db + (1.0 - self.attack_coeff) * self.y1;
        if self.gain_db < self.min_gain_db {
            self.min_gain_db = self.gain_db;
        }

        let gain = db_to_lin(self.gain_db) * self.makeup_lin;
        let wet_l = l * gain;
        let wet_r = r * gain;
        let mix = self.params.mix;
        if mix >= 0.999 {
            (wet_l, wet_r)
        } else {
            (
                wet_l * mix + l * (1.0 - mix),
                wet_r * mix + r * (1.0 - mix),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FS: f32 = 48_000.0;

    #[test]
    fn quiet_signal_passes_untouched() {
        let mut c = Compressor::new(FS, CompParams {
            auto_makeup: false,
            ..CompParams::default()
        });
        for _ in 0..48_000 {
            let (l, r) = c.process(0.01, -0.01);
            assert!((l - 0.01).abs() < 1e-4, "l {l}");
            assert!((r + 0.01).abs() < 1e-4, "r {r}");
        }
        assert!(c.gain_reduction_db() > -0.2);
    }

    #[test]
    fn loud_signal_is_reduced() {
        let params = CompParams {
            attack_ms: 1.0,
            auto_makeup: false,
            ..CompParams::default()
        };
        let mut c = Compressor::new(FS, params);
        let mut peak = 0.0_f32;
        for i in 0..48_000 {
            let (l, _) = c.process(0.9, 0.9);
            // Ignore the attack transient; measure settled behaviour.
            if i > FS as usize / 10 {
                peak = peak.max(l);
            }
        }
        // 0.9 in ≈ -0.9 dBFS, threshold -18, ratio 3 → about -12.6 dB out
        assert!(peak < 0.4, "peak {peak}");
        assert!(c.gain_reduction_db() < -8.0);
    }

    #[test]
    fn transfer_curve_is_monotonic_and_bounded() {
        let p = CompParams::default();
        let mut prev = -100.0;
        for i in -60..=0 {
            let out = p.transfer_db(i as f32);
            assert!(out >= prev - 1e-4);
            assert!(out <= i as f32 + 1e-4);
            prev = out;
        }
    }

    #[test]
    fn makeup_compensates_threshold() {
        let p = CompParams {
            threshold_db: -20.0,
            ratio: 4.0,
            ..CompParams::default()
        };
        assert!((p.auto_makeup_db() - 9.0).abs() < 1e-3);
        // 0 dBFS in → −15 dB of reduction + 9 dB makeup = −6 dBFS out
        let out = p.transfer_db(0.0) + p.effective_makeup_db();
        assert!((out + 6.0).abs() < 0.01, "out {out}");
    }
}
