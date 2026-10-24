//! Look-ahead brickwall limiter with a soft-clip safety stage.
//!
//! The detector runs `lookahead` samples ahead of the audio; gain reduction
//! therefore starts before the transient reaches the output. Release is a
//! one-pole, attack is a short ramp sized to the lookahead window.

use super::util::{coeff_for_ms, db_to_lin, lin_to_db, soft_clip};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimiterParams {
    pub enabled: bool,
    /// Output ceiling, dBFS. −0.3 is a safe default for 32-bit float renders.
    pub ceiling_db: f32,
    pub release_ms: f32,
    pub lookahead_ms: f32,
}

impl Default for LimiterParams {
    fn default() -> Self {
        Self {
            enabled: true,
            ceiling_db: -0.3,
            release_ms: 120.0,
            lookahead_ms: 5.0,
        }
    }
}

impl LimiterParams {
    pub fn sanitized(mut self) -> Self {
        self.ceiling_db = self.ceiling_db.clamp(-12.0, 0.0);
        self.release_ms = self.release_ms.clamp(10.0, 1_000.0);
        self.lookahead_ms = self.lookahead_ms.clamp(0.5, 20.0);
        self
    }
}

pub struct Limiter {
    sample_rate: f32,
    params: LimiterParams,
    left: Vec<f32>,
    right: Vec<f32>,
    write: usize,
    lookahead: usize,
    attack: f32,
    release: f32,
    envelope: f32,
    ceiling_lin: f32,
    min_gain_db: f32,
}

impl Limiter {
    pub fn new(sample_rate: f32, params: LimiterParams) -> Self {
        let params = params.sanitized();
        let max_lookahead = (0.05 * sample_rate) as usize + 4;
        let mut limiter = Self {
            sample_rate,
            params,
            left: vec![0.0; max_lookahead],
            right: vec![0.0; max_lookahead],
            write: 0,
            lookahead: 1,
            attack: 1.0,
            release: 0.0,
            envelope: 1.0,
            ceiling_lin: 1.0,
            min_gain_db: 0.0,
        };
        limiter.update(sample_rate, params);
        limiter
    }

    pub fn update(&mut self, sample_rate: f32, params: LimiterParams) {
        self.sample_rate = sample_rate;
        self.params = params.sanitized();
        self.lookahead = ((self.params.lookahead_ms * 0.001 * sample_rate) as usize).max(1);
        self.lookahead = self.lookahead.min(self.left.len() - 2);
        // Reach the target inside the lookahead window: ~99.9% in N samples.
        self.attack = (1.0 / (0.15 * self.lookahead as f32)).min(1.0);
        self.release = 1.0 - coeff_for_ms(self.params.release_ms, sample_rate);
        self.ceiling_lin = db_to_lin(self.params.ceiling_db);
        self.envelope = 1.0;
        self.left.iter_mut().for_each(|s| *s = 0.0);
        self.right.iter_mut().for_each(|s| *s = 0.0);
        self.write = 0;
        self.min_gain_db = 0.0;
    }

    pub fn gain_reduction_db(&self) -> f32 {
        self.min_gain_db
    }

    #[inline]
    fn delayed(&mut self, l: f32, r: f32) -> (f32, f32) {
        let read = (self.write + self.left.len() - self.lookahead) % self.left.len();
        let out = (self.left[read], self.right[read]);
        self.left[self.write] = l;
        self.right[self.write] = r;
        self.write = (self.write + 1) % self.left.len();
        out
    }

    /// Returns limited output. Always applies the soft-clip safety net at the
    /// ceiling, so a disabled limiter is a bypass, not an unclipped output.
    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.params.enabled {
            return (l, r);
        }
        let peak = l.abs().max(r.abs());
        let target = if peak > self.ceiling_lin {
            self.ceiling_lin / peak
        } else {
            1.0
        };

        // Gain moves down fast (predicted ahead of the audio) and up slowly.
        if target < self.envelope {
            self.envelope += (target - self.envelope) * self.attack;
        } else {
            self.envelope += (target - self.envelope) * self.release;
        }
        self.envelope = self.envelope.clamp(0.0, 1.0);

        let (dl, dr) = self.delayed(l, r);
        let gain_db = lin_to_db(self.envelope);
        if gain_db < self.min_gain_db {
            self.min_gain_db = gain_db;
        }

        let ceiling = self.ceiling_lin;
        (
            soft_clip(dl * self.envelope, ceiling),
            soft_clip(dr * self.envelope, ceiling),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_never_exceeds_ceiling() {
        let params = LimiterParams::default();
        let ceiling = db_to_lin(params.ceiling_db);
        let mut lim = Limiter::new(48_000.0, params);
        let mut peak = 0.0_f32;
        for i in 0..480_000 {
            let t = i as f32 / 48_000.0;
            let x = (t * 110.0 * std::f32::consts::TAU).sin() * 4.0;
            let (l, r) = lim.process(x, x);
            assert!(l.is_finite() && r.is_finite());
            peak = peak.max(l.abs()).max(r.abs());
        }
        assert!(peak <= ceiling + 1e-4, "peak {peak} > ceiling {ceiling}");
        assert!(lim.gain_reduction_db() < -8.0, "no limiting reported");
    }

    #[test]
    fn quiet_signal_is_untouched() {
        let mut lim = Limiter::new(48_000.0, LimiterParams::default());
        // Let the lookahead fill.
        for _ in 0..1_000 {
            lim.process(0.0, 0.0);
        }
        let lookahead = (5.0 * 0.001 * 48_000.0) as usize;
        for i in 0..48_000 {
            let x = (i as f32 * 0.01).sin() * 0.1;
            let (l, _) = lim.process(x, x);
            // The output is delayed by the lookahead window.
            if i > lookahead + 10 {
                let expected = ((i - lookahead) as f32 * 0.01).sin() * 0.1;
                assert!((l - expected).abs() < 1e-4, "{l} vs {expected} at {i}");
            }
        }
    }

    #[test]
    fn disabled_is_a_bypass() {
        let params = LimiterParams {
            enabled: false,
            ..LimiterParams::default()
        };
        let mut lim = Limiter::new(48_000.0, params);
        assert_eq!(lim.process(2.5, -3.0), (2.5, -3.0));
    }
}
