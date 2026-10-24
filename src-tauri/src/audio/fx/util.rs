//! Shared DSP helpers: dB conversions, smoothing coefficients, saturation.

/// Linear amplitude → decibels. Silence floors at −120 dB.
#[inline]
pub fn lin_to_db(x: f32) -> f32 {
    if x <= 1e-6 {
        -120.0
    } else {
        20.0 * x.log10()
    }
}

#[inline]
pub fn db_to_lin(db: f32) -> f32 {
    10.0_f32.powf(db / 20.0)
}

/// One-pole coefficient for a time constant in milliseconds.
#[inline]
pub fn coeff_for_ms(ms: f32, sample_rate: f32) -> f32 {
    (-1.0 / (ms.max(0.01) * 0.001 * sample_rate)).exp()
}

/// Piecewise Hermite soft clipper. Exactly linear below 75% of `ceiling`,
/// unity slope at the knee, zero slope at the ceiling — transparent until it
/// actually matters. (The cubic `1.5(x − x³/3)` is 1.5× hot at zero and cannot
/// be used as a safety stage.)
#[inline]
pub fn soft_clip(x: f32, ceiling: f32) -> f32 {
    let c = ceiling.abs().max(1e-6);
    let knee = 0.75 * c;
    let s = x.abs();
    let y = if s <= knee {
        s
    } else if s < c {
        let t = (s - knee) / (c - knee);
        let t2 = t * t;
        let t3 = t2 * t;
        (2.0 * t3 - 3.0 * t2 + 1.0) * knee
            + (t3 - 2.0 * t2 + t) * (c - knee)
            + (-2.0 * t3 + 3.0 * t2) * c
    } else {
        c
    };
    y.copysign(x)
}

#[inline]
pub fn flush_denormal(x: f32) -> f32 {
    if x.abs() < 1e-20 {
        0.0
    } else {
        x
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn db_round_trip() {
        for db in [-60.0, -12.0, 0.0, 6.0] {
            assert!((lin_to_db(db_to_lin(db)) - db).abs() < 1e-4);
        }
    }

    #[test]
    fn soft_clip_is_bounded_and_monotonic() {
        let c = 0.966;
        let mut prev = f32::NEG_INFINITY;
        for i in -200..=200 {
            let y = soft_clip(i as f32 / 100.0, c);
            assert!(y.abs() <= c + 1e-5);
            assert!(y >= prev);
            prev = y;
        }
        // transparent below the knee
        assert!((soft_clip(0.1, c) - 0.1).abs() < 1e-6);
        assert!((soft_clip(0.5, c) - 0.5).abs() < 1e-6);
        assert!((soft_clip(c, c) - c).abs() < 1e-6);
        assert!((soft_clip(-c, c) + c).abs() < 1e-6);
        assert!(soft_clip(4.0, c) <= c);
    }
}
