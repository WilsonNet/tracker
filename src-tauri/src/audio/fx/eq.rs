//! Three-band channel EQ: low shelf → mid bell → high shelf.

use super::biquad::Biquad;
use serde::{Deserialize, Serialize};

pub const LOW_SHELF_HZ: f32 = 110.0;
pub const HIGH_SHELF_HZ: f32 = 7_500.0;

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EqParams {
    pub enabled: bool,
    /// Low shelf gain, dB.
    pub low_db: f32,
    /// Mid bell gain, dB.
    pub mid_db: f32,
    /// Mid bell centre, Hz.
    pub mid_hz: f32,
    /// Mid bell width.
    pub mid_q: f32,
    /// High shelf gain, dB.
    pub high_db: f32,
}

impl Default for EqParams {
    fn default() -> Self {
        Self {
            enabled: true,
            low_db: 0.0,
            mid_db: 0.0,
            mid_hz: 1_000.0,
            mid_q: 1.0,
            high_db: 0.0,
        }
    }
}

impl EqParams {
    pub fn sanitized(mut self) -> Self {
        self.low_db = self.low_db.clamp(-18.0, 18.0);
        self.mid_db = self.mid_db.clamp(-18.0, 18.0);
        self.high_db = self.high_db.clamp(-18.0, 18.0);
        self.mid_hz = self.mid_hz.clamp(150.0, 8_000.0);
        self.mid_q = self.mid_q.clamp(0.3, 8.0);
        self
    }

    pub fn is_active(&self) -> bool {
        self.enabled
            && (self.low_db.abs() > 0.05 || self.mid_db.abs() > 0.05 || self.high_db.abs() > 0.05)
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct StereoBiquad {
    left: Biquad,
    right: Biquad,
}

impl StereoBiquad {
    fn from(mut left: Biquad, mut right: Biquad) -> Self {
        left.reset();
        right.reset();
        Self { left, right }
    }

    #[inline]
    fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        (self.left.process(l), self.right.process(r))
    }
}

pub struct ChannelEq {
    low: StereoBiquad,
    mid: StereoBiquad,
    high: StereoBiquad,
    active: bool,
}

impl ChannelEq {
    pub fn new(sample_rate: f32, params: EqParams) -> Self {
        let params = params.sanitized();
        let mut eq = Self {
            low: StereoBiquad::default(),
            mid: StereoBiquad::default(),
            high: StereoBiquad::default(),
            active: params.is_active(),
        };
        eq.update(sample_rate, params);
        eq
    }

    pub fn update(&mut self, sample_rate: f32, params: EqParams) {
        let params = params.sanitized();
        self.active = params.is_active();
        self.low = StereoBiquad::from(
            Biquad::low_shelf(sample_rate, LOW_SHELF_HZ, params.low_db, 1.0),
            Biquad::low_shelf(sample_rate, LOW_SHELF_HZ, params.low_db, 1.0),
        );
        self.mid = StereoBiquad::from(
            Biquad::peaking(sample_rate, params.mid_hz, params.mid_q, params.mid_db),
            Biquad::peaking(sample_rate, params.mid_hz, params.mid_q, params.mid_db),
        );
        self.high = StereoBiquad::from(
            Biquad::high_shelf(sample_rate, HIGH_SHELF_HZ, params.high_db, 1.0),
            Biquad::high_shelf(sample_rate, HIGH_SHELF_HZ, params.high_db, 1.0),
        );
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.active {
            return (l, r);
        }
        let (l, r) = self.low.process(l, r);
        let (l, r) = self.mid.process(l, r);
        self.high.process(l, r)
    }

    /// Combined magnitude response in dB at `freq` (left channel).
    #[cfg(test)]
    pub fn response_db(&self, sample_rate: f32, freq: f32) -> f32 {
        if !self.active {
            return 0.0;
        }
        super::util::lin_to_db(
            self.low.left.magnitude_at(sample_rate, freq)
                * self.mid.left.magnitude_at(sample_rate, freq)
                * self.high.left.magnitude_at(sample_rate, freq),
        )
    }
}

/// Convenience wrapper for tests: response of a static parameter set.
#[cfg(test)]
pub fn response_curve(sample_rate: f32, params: EqParams, freqs: &[f32]) -> Vec<f32> {
    let eq = ChannelEq::new(sample_rate, params);
    freqs.iter().map(|&f| eq.response_db(sample_rate, f)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flat_eq_is_a_passthrough() {
        let params = EqParams::default();
        assert!(!params.is_active());
        let mut eq = ChannelEq::new(48_000.0, params);
        for i in 0..1_000 {
            let x = (i as f32 / 100.0).sin() * 0.5;
            assert_eq!(eq.process(x, x), (x, x));
        }
    }

    #[test]
    fn boosts_low_end_only() {
        let params = EqParams {
            low_db: 6.0,
            ..EqParams::default()
        };
        let curve = response_curve(48_000.0, params, &[40.0, 110.0, 1_000.0, 10_000.0]);
        assert!(curve[0] > 4.5, "40Hz boost: {:?}", curve);
        assert!(curve[2].abs() < 0.2, "1kHz flat: {:?}", curve);
        assert!(curve[3].abs() < 0.6, "10kHz flat: {:?}", curve);
    }

    #[test]
    fn cuts_are_negative() {
        let params = EqParams {
            mid_db: -9.0,
            mid_hz: 900.0,
            mid_q: 2.0,
            ..EqParams::default()
        };
        let curve = response_curve(48_000.0, params, &[900.0]);
        assert!(curve[0] < -8.5, "mid cut: {:?}", curve);
    }
}
