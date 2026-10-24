# Native Effects — Algorithm & Source Notes

All effects are written from public-domain papers and permissively licensed
reference implementations. Nothing is copied from GPL code; no plugin host, no
VST, no external DSP crate.

## Per-track chain

### 3-band EQ — RBJ biquads
- **Algorithm:** Robert Bristow-Johnson, *Audio EQ Cookbook* (W3C Working Group
  Note, 2021): low shelf, peaking EQ, high shelf; transposed direct form II.
- **Why:** five multiplies per sample, exact closed-form coefficients, the
  lingua franca of audio DSP (easy to verify against any analyser).
- **Design:** low shelf 110 Hz, mid bell 150 Hz–8 kHz (Q 0.3–8), high shelf
  7.5 kHz; ±18 dB. Flat/disabled → true bypass (zero state touched).
- **Rejected:** Cytomic/Simper SVF — better for audio-rate modulation, but ~2×
  the multiplies and unnecessary for static knobs. Read: `korken89/biquad-rs`
  (Apache-2.0), `BartMassey/rbj-eq` (MIT), `neodsp/simper-filter` (Apache-2.0).

### Compressor — feed-forward, soft knee, decoupled detector
- **Paper:** Giannoulis, Massberg & Reiss, *Digital Dynamic Range Compressor
  Design — A Tutorial and Analysis*, JAES 60(6), 2012 (eqs. 3, 4, 17).
- **Implementation:** peak detector (max |L|,|R|) → static dB curve with
  quadratic knee → smooth decoupled release/attack on the gain signal → makeup.
  Auto-makeup = `0.6 × (−threshold) × (1 − 1/ratio)` (the textbook "unity at
  0 dBFS" value is too hot on real material).
- **Ranges:** threshold −60…0 dB, ratio 1–20:1, attack 0.1–300 ms, release
  5–2000 ms, knee 0–24 dB.
- No GPL references used. `juce_dsp`'s ballistics use a different time-constant
  convention (`exp(−2π/τfs)`); we use the paper's `exp(−1/τfs)`.

## Shared buses (master)

### Reverb — 8-line Householder FDN
- **Algorithm:** feedback delay network with `y = x − (2/N)·Σx` Householder
  feedback, 8 prime delay lengths (31–86 ms at 48 kHz), per-line damping,
  ±4-sample slow modulation, zero-sum input injection, two orthogonal (Hadamard)
  output taps. Exact RT60 from `g_i = 10^(−3·L_i/(fs·RT60))`.
- **Diffusion:** four Dattorro input allpasses (0.75/0.75/0.625/0.625), from
  J. Dattorro, *Effect Design Part 1*, JAES 45(9), 1997.
- **Why not Freeverb:** eight parallel combs ring metallically and "size" is only
  a feedback change. Why not Dattorro as the core: no honest size control, and
  its 14 signed output taps are error-prone.
- **Reference implementations read (not copied):** `MindBuffer/lanceverb` (MIT),
  `irh/freeverb-rs` (MIT), Faust `reverbs.lib`. Avoided: ValleyRackFree,
  `zita-rev1`, mverb (GPL).

### Delay — stereo / ping-pong with tape character
- Fractional read with **linear interpolation** (allpass interpolation becomes
  unstable under modulation), 20 ms time glide, feedback clamped to 0.9,
  `tanh` saturation + DC blocker inside the loop, one-pole tone filter.
- Ping-pong: mono feed → left line → right line → left.
- **References:** `dllim/anotherdelay` (MIT), Airwindows tape delay (MIT).
  Avoided `IV-XDelay` (GPL).

### Widener — mid/side with bass mono (master only)
- `M = (L+R)/2`, `S = (L−R)/2`; complementary side-only split at the bass
  crossover (two cascaded one-poles); low side collapses to mono as width
  increases; static peak trim `1/(1 + 0.5·max(0, width−1))`.
- The mono sum `L+R = 2M` is unchanged for any width — no phase cancellation.
- **References:** DAFx 2024 open-source stereo widener
  (`orchidas/StereoWidener`, CC0), DeaDBeeF `stereo-widener` (MIT). Avoided
  Haas delay (comb filtering in mono) and GPL all-pass wideners.

### Limiter — look-ahead brickwall + Hermite soft clip
- Detector runs 5 ms ahead (delay line); gain attacks within the lookahead and
  releases with a one-pole (10–1000 ms); final piecewise-Hermite clipper at the
  ceiling (linear below 75% of ceiling, unity slope at the knee, zero slope at
  the ceiling). The classic `1.5(x − x³/3)` cubic is 1.5× hot at zero and is not
  safe as a safety stage.
- **References:** Fons Adriaensen's zita design as documented in `x42/dpl.lv2`
  (GPL — read for technique only), ITU-R BS.1770-4 Annex 2 (true peak, not
  implemented).

## Verification

- `cd src-tauri && cargo test --lib` — 34 tests: filter magnitude responses,
  compressor transfer curve/makeup, reverb decay + stereo decorrelation,
  delay echo timing + feedback stability, widener mono-sum invariance, limiter
  ceiling, full mixdown, stereo WAV write, UI JSON payload.
- `npm run test:e2e` — 26 browser tests, including the rack.
