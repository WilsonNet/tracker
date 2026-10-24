//! Stereo delay with a tone control in the feedback path and an optional
//! ping-pong routing (mono input, left → right → left).
//!
//! The read tap is fractional (linear interpolation) and the delay time is
//! smoothed, so moving TIME while audio is running never clicks.

use super::util::{coeff_for_ms, flush_denormal};
use serde::{Deserialize, Serialize};

const MAX_DELAY_SECONDS: f32 = 2.0;

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DelayParams {
    pub enabled: bool,
    pub time_ms: f32,
    pub feedback: f32,
    /// 0 = dark repeats, 1 = bright.
    pub tone: f32,
    pub ping_pong: bool,
    /// Wet return level, 0..1 (this is a send bus, so it is wet only).
    pub return_level: f32,
}

impl Default for DelayParams {
    fn default() -> Self {
        Self {
            enabled: false,
            time_ms: 320.0,
            feedback: 0.35,
            tone: 0.55,
            ping_pong: true,
            return_level: 0.35,
        }
    }
}

impl DelayParams {
    pub fn sanitized(mut self) -> Self {
        self.time_ms = self.time_ms.clamp(1.0, 2_000.0);
        self.feedback = self.feedback.clamp(0.0, 0.9);
        self.tone = self.tone.clamp(0.0, 1.0);
        self.return_level = self.return_level.clamp(0.0, 1.0);
        self
    }
}

struct Line {
    buffer: Vec<f32>,
    write: usize,
}

impl Line {
    fn new(max: usize) -> Self {
        Self {
            buffer: vec![0.0; max.max(2)],
            write: 0,
        }
    }

    #[inline]
    fn read(&self, delay: f32) -> f32 {
        let len = self.buffer.len();
        let d = delay.clamp(1.0, (len - 2) as f32);
        let read = self.write as f32 - d;
        let read = if read < 0.0 { read + len as f32 } else { read };
        let i0 = read.floor() as usize % len;
        let i1 = (i0 + 1) % len;
        let frac = read - read.floor();
        self.buffer[i0] * (1.0 - frac) + self.buffer[i1] * frac
    }

    #[inline]
    fn write(&mut self, x: f32) {
        self.buffer[self.write] = flush_denormal(x);
        self.write += 1;
        if self.write >= self.buffer.len() {
            self.write = 0;
        }
    }
}

pub struct StereoDelay {
    left: Line,
    right: Line,
    sample_rate: f32,
    params: DelayParams,
    delay_samples: f32,
    target_samples: f32,
    smoothing: f32,
    tone_l: f32,
    tone_r: f32,
    tone_coeff: f32,
    dc_x_l: f32,
    dc_y_l: f32,
    dc_x_r: f32,
    dc_y_r: f32,
}

impl StereoDelay {
    pub fn new(sample_rate: f32, params: DelayParams) -> Self {
        let params = params.sanitized();
        let max = (MAX_DELAY_SECONDS * sample_rate) as usize + 8;
        let mut delay = Self {
            left: Line::new(max),
            right: Line::new(max),
            sample_rate,
            params,
            delay_samples: params.time_ms * 0.001 * sample_rate,
            target_samples: params.time_ms * 0.001 * sample_rate,
            smoothing: 0.0,
            tone_l: 0.0,
            tone_r: 0.0,
            tone_coeff: 1.0,
            dc_x_l: 0.0,
            dc_y_l: 0.0,
            dc_x_r: 0.0,
            dc_y_r: 0.0,
        };
        delay.update(sample_rate, params);
        delay.delay_samples = delay.target_samples;
        delay
    }

    pub fn update(&mut self, sample_rate: f32, params: DelayParams) {
        self.sample_rate = sample_rate;
        self.params = params.sanitized();
        self.target_samples = self.params.time_ms * 0.001 * sample_rate;
        // 20 ms glide for the read tap
        self.smoothing = coeff_for_ms(20.0, sample_rate);
        let cutoff = 400.0 + 16_000.0 * self.params.tone;
        self.tone_coeff = 1.0 - (-std::f32::consts::TAU * cutoff / sample_rate).exp();
    }

    /// Soft saturation plus a DC blocker, applied inside the feedback loop.
    /// Bounds the state at any feedback setting and keeps repeats from building
    /// a DC offset.
    #[inline]
    fn shape(&mut self, x: f32, channel: usize) -> f32 {
        let saturated = (1.5 * x).tanh() * 0.6667;
        let (x1, y1) = if channel == 0 {
            (&mut self.dc_x_l, &mut self.dc_y_l)
        } else {
            (&mut self.dc_x_r, &mut self.dc_y_r)
        };
        let y = saturated - *x1 + 0.995 * *y1;
        *x1 = saturated;
        *y1 = y;
        y
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.params.enabled || self.params.return_level <= 0.0001 {
            return (0.0, 0.0);
        }
        self.delay_samples = self.smoothing * self.delay_samples
            + (1.0 - self.smoothing) * self.target_samples;

        let wet_l = self.left.read(self.delay_samples);
        let wet_r = self.right.read(self.delay_samples);

        // Each repeat gets darker and slightly saturated, like tape.
        self.tone_l += self.tone_coeff * (wet_l - self.tone_l);
        self.tone_r += self.tone_coeff * (wet_r - self.tone_r);
        let fb_l = self.shape(self.tone_l, 0);
        let fb_r = self.shape(self.tone_r, 1);
        let fb = self.params.feedback;

        if self.params.ping_pong {
            // Mono feed → left line → right line → left line ...
            let mono = (l + r) * 0.5;
            self.left.write(mono + fb_r * fb);
            self.right.write(fb_l * fb);
        } else {
            self.left.write(l + fb_l * fb);
            self.right.write(r + fb_r * fb);
        }

        let level = self.params.return_level;
        (wet_l * level, wet_r * level)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_in_silence_out() {
        let mut d = StereoDelay::new(48_000.0, DelayParams {
            enabled: true,
            return_level: 1.0,
            ..DelayParams::default()
        });
        for _ in 0..10_000 {
            let (l, r) = d.process(0.0, 0.0);
            assert_eq!((l, r), (0.0, 0.0));
        }
    }

    #[test]
    fn repeats_appear_at_the_delay_time() {
        let params = DelayParams {
            enabled: true,
            time_ms: 100.0,
            feedback: 0.5,
            ping_pong: false,
            return_level: 1.0,
            ..DelayParams::default()
        };
        let mut d = StereoDelay::new(48_000.0, params);
        let delay_samples = 4_800;
        let mut first_echo = None;
        for i in 0..20_000 {
            let x = if i == 0 { 1.0 } else { 0.0 };
            let (l, _) = d.process(x, x);
            if l.abs() > 0.01 && first_echo.is_none() && i > 10 {
                first_echo = Some(i);
            }
        }
        let echo = first_echo.expect("no echo");
        assert!(
            (echo as i32 - delay_samples as i32).abs() < 5,
            "echo at {echo}, expected {delay_samples}"
        );
    }

    #[test]
    fn feedback_never_blows_up() {
        let params = DelayParams {
            enabled: true,
            time_ms: 10.0,
            feedback: 0.9,
            return_level: 1.0,
            ..DelayParams::default()
        };
        let mut d = StereoDelay::new(48_000.0, params);
        let mut peak = 0.0_f32;
        for i in 0..480_000 {
            let x = if i % 480 == 0 { 0.9 } else { 0.0 };
            let (l, r) = d.process(x, x);
            peak = peak.max(l.abs()).max(r.abs());
        }
        assert!(peak.is_finite(), "delay diverged");
        assert!(peak < 10.0, "delay runaway: {peak}");
    }
}
