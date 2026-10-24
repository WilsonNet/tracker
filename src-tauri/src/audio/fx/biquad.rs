//! Biquad filters — Robert Bristow-Johnson "Audio EQ Cookbook".
//!
//! Transposed direct form II: two state words, good numerical behaviour for
//! float audio, one multiply-add per coefficient.

#[derive(Clone, Copy, Debug, Default)]
pub struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32,
    z2: f32,
}

#[inline]
fn flush(x: f32) -> f32 {
    if x.abs() < 1e-20 {
        0.0
    } else {
        x
    }
}

impl Biquad {
    /// Peaking EQ. `gain_db` positive boosts, `q` sets bandwidth.
    pub fn peaking(fs: f32, freq: f32, q: f32, gain_db: f32) -> Self {
        let a = 10.0_f32.powf(gain_db / 40.0);
        let w0 = std::f32::consts::TAU * (freq / fs).clamp(1e-5, 0.49);
        let cos_w0 = w0.cos();
        let alpha = w0.sin() / (2.0 * q.max(0.05));
        let a0 = 1.0 + alpha / a;
        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cos_w0) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cos_w0) / a0,
            a2: (1.0 - alpha / a) / a0,
            z1: 0.0,
            z2: 0.0,
        }
    }

    /// Low shelf. `slope` of 1.0 is the RBJ default (Q ≈ 0.707).
    pub fn low_shelf(fs: f32, freq: f32, gain_db: f32, slope: f32) -> Self {
        let a = 10.0_f32.powf(gain_db / 40.0);
        let w0 = std::f32::consts::TAU * (freq / fs).clamp(1e-5, 0.49);
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / 2.0 * ((a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0).sqrt();
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;
        let a0 = (a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha;
        Self {
            b0: a * ((a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha) / a0,
            b1: 2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0) / a0,
            b2: a * ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
            a1: -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0) / a0,
            a2: ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
            z1: 0.0,
            z2: 0.0,
        }
    }

    /// High shelf. `slope` of 1.0 is the RBJ default.
    pub fn high_shelf(fs: f32, freq: f32, gain_db: f32, slope: f32) -> Self {
        let a = 10.0_f32.powf(gain_db / 40.0);
        let w0 = std::f32::consts::TAU * (freq / fs).clamp(1e-5, 0.49);
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / 2.0 * ((a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0).sqrt();
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;
        let a0 = (a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha;
        Self {
            b0: a * ((a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha) / a0,
            b1: -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0) / a0,
            b2: a * ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
            a1: 2.0 * ((a - 1.0) - (a + 1.0) * cos_w0) / a0,
            a2: ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
            z1: 0.0,
            z2: 0.0,
        }
    }

    #[inline]
    pub fn process(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.z1;
        self.z1 = flush(self.b1 * x - self.a1 * y + self.z2);
        self.z2 = flush(self.b2 * x - self.a2 * y);
        y
    }

    pub fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    /// Complex magnitude response at `freq`, computed from the transfer
    /// function. Used by the EQ tests.
    #[cfg(test)]
    pub fn magnitude_at(&self, fs: f32, freq: f32) -> f32 {
        let w = std::f32::consts::TAU * freq / fs;
        let (sin1, cos1) = w.sin_cos();
        let (sin2, cos2) = (2.0 * w).sin_cos();
        let num_re = self.b0 + self.b1 * cos1 + self.b2 * cos2;
        let num_im = -(self.b1 * sin1 + self.b2 * sin2);
        let den_re = 1.0 + self.a1 * cos1 + self.a2 * cos2;
        let den_im = -(self.a1 * sin1 + self.a2 * sin2);
        ((num_re * num_re + num_im * num_im) / (den_re * den_re + den_im * den_im)).sqrt()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FS: f32 = 48_000.0;

    fn db(x: f32) -> f32 {
        20.0 * x.max(1e-12).log10()
    }

    #[test]
    fn peaking_boosts_at_center() {
        let f = Biquad::peaking(FS, 1_000.0, 1.0, 6.0);
        assert!((db(f.magnitude_at(FS, 1_000.0)) - 6.0).abs() < 0.15);
        // far from the bell the filter is transparent
        assert!(db(f.magnitude_at(FS, 20.0)).abs() < 0.5);
        assert!(db(f.magnitude_at(FS, 20_000.0)).abs() < 0.5);
    }

    #[test]
    fn shelves_reach_target_gain() {
        let low = Biquad::low_shelf(FS, 120.0, 9.0, 1.0);
        assert!((db(low.magnitude_at(FS, 20.0)) - 9.0).abs() < 0.6);
        let high = Biquad::high_shelf(FS, 8_000.0, -6.0, 1.0);
        assert!((db(high.magnitude_at(FS, 20_000.0)) + 6.0).abs() < 0.8);
    }

    #[test]
    fn flat_settings_are_transparent() {
        let f = Biquad::peaking(FS, 1_000.0, 1.0, 0.0);
        for freq in [30.0, 100.0, 1_000.0, 10_000.0, 18_000.0] {
            assert!(db(f.magnitude_at(FS, freq)).abs() < 0.01);
        }
    }

    #[test]
    fn stays_finite_on_noise_burst() {
        let mut f = Biquad::high_shelf(FS, 8_000.0, 12.0, 1.0);
        let mut seed = 0x1234_5678_u32;
        for i in 0..48_000 {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let x = ((seed >> 8) as f32 / 8_388_608.0) - 1.0;
            let y = f.process(x);
            assert!(y.is_finite(), "diverged at sample {i}");
        }
    }
}
