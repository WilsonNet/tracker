// Effects model shared by the rack UI.
//
// The numbers here mirror `src-tauri/src/audio/fx/*` — same defaults, same
// ranges, same formulas for the response curves the UI draws. Keep them in
// sync; the Rust side is the source of truth for audio.

export const FX_SAMPLE_RATE = 48_000;

export interface EqParams {
  enabled: boolean;
  lowDb: number;
  midDb: number;
  midHz: number;
  midQ: number;
  highDb: number;
}

export interface CompParams {
  enabled: boolean;
  thresholdDb: number;
  ratio: number;
  attackMs: number;
  releaseMs: number;
  kneeDb: number;
  makeupDb: number;
  mix: number;
  autoMakeup: boolean;
}

export interface ReverbParams {
  enabled: boolean;
  size: number;
  decay: number;
  tone: number;
  predelayMs: number;
  returnLevel: number;
}

export interface DelayParams {
  enabled: boolean;
  timeMs: number;
  feedback: number;
  tone: number;
  pingPong: boolean;
  returnLevel: number;
  /** UI-only: snap time to the transport tempo. */
  sync: boolean;
  /** UI-only: index into DELAY_DIVISIONS. */
  division: number;
}

export interface WidthParams {
  enabled: boolean;
  width: number;
  bassHz: number;
}

export interface LimiterParams {
  enabled: boolean;
  ceilingDb: number;
  releaseMs: number;
  lookaheadMs: number;
}

export interface TrackFxSettings {
  eq: EqParams;
  comp: CompParams;
  sendReverb: number;
  sendDelay: number;
}

export interface FxState {
  tracks: TrackFxSettings[];
  masterComp: CompParams;
  reverb: ReverbParams;
  delay: DelayParams;
  width: WidthParams;
  limiter: LimiterParams;
}

/** The exact payload `bounce_tracks` / `preview_mix` expect. */
export interface MixSettings {
  tracks: Array<
    TrackFxSettings & { level: number; pan: number; muted: boolean }
  >;
  masterComp: CompParams;
  reverb: ReverbParams;
  delay: DelayParams;
  width: WidthParams;
  limiter: LimiterParams;
}

export const LOW_SHELF_HZ = 110;
export const HIGH_SHELF_HZ = 7_500;

export function defaultEq(): EqParams {
  return {
    enabled: true,
    lowDb: 0,
    midDb: 0,
    midHz: 1_000,
    midQ: 1,
    highDb: 0,
  };
}

export function defaultComp(): CompParams {
  return {
    enabled: false,
    thresholdDb: -18,
    ratio: 3,
    attackMs: 12,
    releaseMs: 180,
    kneeDb: 8,
    makeupDb: 0,
    mix: 1,
    autoMakeup: true,
  };
}

export function defaultMasterComp(): CompParams {
  return {
    ...defaultComp(),
    thresholdDb: -14,
    ratio: 2.5,
    attackMs: 20,
    releaseMs: 250,
    kneeDb: 10,
  };
}

export function defaultReverb(): ReverbParams {
  return {
    enabled: false,
    size: 0.62,
    decay: 0.55,
    tone: 0.55,
    predelayMs: 18,
    returnLevel: 0.45,
  };
}

export function defaultDelay(): DelayParams {
  return {
    enabled: false,
    timeMs: 320,
    feedback: 0.35,
    tone: 0.55,
    pingPong: true,
    returnLevel: 0.35,
    sync: false,
    division: 2,
  };
}

export function defaultWidth(): WidthParams {
  return { enabled: false, width: 1.25, bassHz: 140 };
}

export function defaultLimiter(): LimiterParams {
  return {
    enabled: true,
    ceilingDb: -0.3,
    releaseMs: 120,
    lookaheadMs: 5,
  };
}

export function defaultTrackFx(): TrackFxSettings {
  return {
    eq: defaultEq(),
    comp: defaultComp(),
    sendReverb: 0,
    sendDelay: 0,
  };
}

export function defaultFxState(trackCount = 4): FxState {
  return {
    tracks: Array.from({ length: trackCount }, defaultTrackFx),
    masterComp: defaultMasterComp(),
    reverb: defaultReverb(),
    delay: defaultDelay(),
    width: defaultWidth(),
    limiter: defaultLimiter(),
  };
}

// ── Tempo sync ────────────────────────────────────────────────────────────

export const DELAY_DIVISIONS = [
  { label: "1/16", beats: 0.25 },
  { label: "1/8T", beats: 1 / 3 },
  { label: "1/8", beats: 0.5 },
  { label: "1/4T", beats: 2 / 3 },
  { label: "1/4", beats: 1 },
  { label: "1/2", beats: 2 },
] as const;

export function syncedDelayMs(division: number, bpm: number): number {
  const d = DELAY_DIVISIONS[Math.max(0, Math.min(DELAY_DIVISIONS.length - 1, division))];
  return (60_000 / Math.max(30, bpm)) * d.beats;
}

/** The time actually sent to the engine (tempo sync resolved here). */
export function effectiveDelayMs(delay: DelayParams, bpm: number): number {
  return delay.sync ? syncedDelayMs(delay.division, bpm) : delay.timeMs;
}

// ── EQ response (RBJ cookbook, matches the Rust biquads) ──────────────────

interface BiquadCoefficients {
  b0: number;
  b1: number;
  b2: number;
  a1: number;
  a2: number;
}

function peaking(fs: number, f0: number, q: number, gainDb: number): BiquadCoefficients {
  const a = Math.pow(10, gainDb / 40);
  const w0 = (2 * Math.PI * Math.min(Math.max(f0 / fs, 1e-5), 0.49));
  const cos = Math.cos(w0);
  const alpha = Math.sin(w0) / (2 * Math.max(0.05, q));
  const a0 = 1 + alpha / a;
  return {
    b0: (1 + alpha * a) / a0,
    b1: (-2 * cos) / a0,
    b2: (1 - alpha * a) / a0,
    a1: (-2 * cos) / a0,
    a2: (1 - alpha / a) / a0,
  };
}

function lowShelf(fs: number, f0: number, gainDb: number, slope = 1): BiquadCoefficients {
  const a = Math.pow(10, gainDb / 40);
  const w0 = 2 * Math.PI * Math.min(Math.max(f0 / fs, 1e-5), 0.49);
  const cos = Math.cos(w0);
  const alpha =
    (Math.sin(w0) / 2) * Math.sqrt((a + 1 / a) * (1 / slope - 1) + 2);
  const beta = 2 * Math.sqrt(a) * alpha;
  const a0 = a + 1 + (a - 1) * cos + beta;
  return {
    b0: (a * (a + 1 - (a - 1) * cos + beta)) / a0,
    b1: (2 * a * (a - 1 - (a + 1) * cos)) / a0,
    b2: (a * (a + 1 - (a - 1) * cos - beta)) / a0,
    a1: (-2 * (a - 1 + (a + 1) * cos)) / a0,
    a2: (a + 1 + (a - 1) * cos - beta) / a0,
  };
}

function highShelf(fs: number, f0: number, gainDb: number, slope = 1): BiquadCoefficients {
  const a = Math.pow(10, gainDb / 40);
  const w0 = 2 * Math.PI * Math.min(Math.max(f0 / fs, 1e-5), 0.49);
  const cos = Math.cos(w0);
  const alpha =
    (Math.sin(w0) / 2) * Math.sqrt((a + 1 / a) * (1 / slope - 1) + 2);
  const beta = 2 * Math.sqrt(a) * alpha;
  const a0 = a + 1 - (a - 1) * cos + beta;
  return {
    b0: (a * (a + 1 + (a - 1) * cos + beta)) / a0,
    b1: (-2 * a * (a - 1 + (a + 1) * cos)) / a0,
    b2: (a * (a + 1 + (a - 1) * cos - beta)) / a0,
    a1: (2 * (a - 1 - (a + 1) * cos)) / a0,
    a2: (a + 1 - (a - 1) * cos - beta) / a0,
  };
}

function magnitude(coeffs: BiquadCoefficients, fs: number, freq: number): number {
  const w = (2 * Math.PI * freq) / fs;
  const sin1 = Math.sin(w);
  const cos1 = Math.cos(w);
  const sin2 = Math.sin(2 * w);
  const cos2 = Math.cos(2 * w);
  const numRe = coeffs.b0 + coeffs.b1 * cos1 + coeffs.b2 * cos2;
  const numIm = -(coeffs.b1 * sin1 + coeffs.b2 * sin2);
  const denRe = 1 + coeffs.a1 * cos1 + coeffs.a2 * cos2;
  const denIm = -(coeffs.a1 * sin1 + coeffs.a2 * sin2);
  return Math.sqrt(
    (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm),
  );
}

/** Combined EQ magnitude in dB at `freq`. Disabled or flat EQ returns 0. */
export function eqResponseDb(eq: EqParams, freq: number, fs = FX_SAMPLE_RATE): number {
  if (!eq.enabled) return 0;
  const low = lowShelf(fs, LOW_SHELF_HZ, eq.lowDb);
  const mid = peaking(fs, eq.midHz, eq.midQ, eq.midDb);
  const high = highShelf(fs, HIGH_SHELF_HZ, eq.highDb);
  const mag = magnitude(low, fs, freq) * magnitude(mid, fs, freq) * magnitude(high, fs, freq);
  return 20 * Math.log10(Math.max(1e-9, mag));
}

// ── Compressor curve ─────────────────────────────────────────────────────

export function autoMakeupDb(comp: CompParams): number {
  if (comp.ratio <= 1.0001) return 0;
  return clamp(0.6 * -comp.thresholdDb * (1 - 1 / comp.ratio), 0, 24);
}

export function effectiveMakeupDb(comp: CompParams): number {
  return comp.autoMakeup ? autoMakeupDb(comp) : comp.makeupDb;
}

/** Static transfer curve: input dB → output dB, makeup included. */
export function compTransferDb(comp: CompParams, inputDb: number): number {
  const slope = 1 - 1 / Math.max(1, comp.ratio);
  const over = inputDb - comp.thresholdDb;
  const knee = comp.kneeDb;
  let reduction: number;
  if (knee <= 0) {
    reduction = Math.max(0, over) * slope;
  } else if (over <= -knee / 2) {
    reduction = 0;
  } else if (over >= knee / 2) {
    reduction = over * slope;
  } else {
    const x = over + knee / 2;
    reduction = (slope * x * x) / (2 * knee);
  }
  return inputDb - reduction + effectiveMakeupDb(comp);
}

/** Gain reduction for a static input level, dB ≤ 0 (pre-makeup). */
export function compReductionDb(comp: CompParams, inputDb: number): number {
  return compTransferDb(comp, inputDb) - effectiveMakeupDb(comp) - inputDb;
}

// ── Formatting ───────────────────────────────────────────────────────────

export function clamp(v: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, v));
}

export function fmtDb(v: number, digits = 1): string {
  if (!Number.isFinite(v) || v <= -119) return "−∞";
  const rounded = Math.abs(v).toFixed(digits);
  if (Number(rounded) === 0) return `0.${"0".repeat(digits)} dB`;
  return `${v > 0 ? "+" : "−"}${rounded} dB`;
}

export function fmtSigned(v: number, digits = 1): string {
  return `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(v).toFixed(digits)}`;
}

export function fmtHz(v: number): string {
  if (v >= 1000) {
    const k = v / 1000;
    return `${k >= 10 ? k.toFixed(1) : k.toFixed(k % 1 === 0 ? 0 : 1)} kHz`;
  }
  return `${Math.round(v)} Hz`;
}

export function fmtMs(v: number): string {
  if (v >= 1000) return `${(v / 1000).toFixed(2)} s`;
  return `${Math.round(v)} ms`;
}

export function fmtPct(v: number): string {
  return `${Math.round(v * 100)}%`;
}

export function fmtRatio(v: number): string {
  return `${v >= 10 ? Math.round(v) : v.toFixed(1)}:1`;
}

export function fmtWidth(v: number): string {
  return `${Math.round(v * 100)}%`;
}

export function fmtSec(v: number): string {
  return `${v.toFixed(1)} s`;
}

/** Reverb RT60 from the decay knob — mirrors `ReverbParams::rt60_seconds`. */
export function reverbRt60(decay: number): number {
  return 0.3 * Math.pow(60, decay);
}

/** Reverb room scale — mirrors `ReverbParams::size_scale`. */
export function reverbSizeScale(size: number): number {
  return 0.25 * Math.pow(4, size);
}

/** Bass-mono amount for the widener. */
export function bassMonoAmount(width: number): number {
  return width <= 1 ? 0 : Math.min(1, width - 1);
}

export function fxModuleCount(fx: TrackFxSettings): number {
  return (
    (fx.eq.enabled && (fx.eq.lowDb !== 0 || fx.eq.midDb !== 0 || fx.eq.highDb !== 0) ? 1 : 0) +
    (fx.comp.enabled ? 1 : 0) +
    (fx.sendReverb > 0.001 ? 1 : 0) +
    (fx.sendDelay > 0.001 ? 1 : 0)
  );
}

export function masterModuleCount(fx: FxState): number {
  return (
    (fx.masterComp.enabled ? 1 : 0) +
    (fx.reverb.enabled ? 1 : 0) +
    (fx.delay.enabled ? 1 : 0) +
    (fx.width.enabled ? 1 : 0) +
    (fx.limiter.enabled ? 1 : 0)
  );
}

/** Short labels for the FX chip on a track strip. */
export function trackFxBadges(fx: TrackFxSettings): string[] {
  const badges: string[] = [];
  if (fx.eq.enabled && (fx.eq.lowDb !== 0 || fx.eq.midDb !== 0 || fx.eq.highDb !== 0)) {
    badges.push("EQ");
  }
  if (fx.comp.enabled) badges.push("CMP");
  if (fx.sendReverb > 0.001) badges.push("REV");
  if (fx.sendDelay > 0.001) badges.push("DLY");
  return badges;
}
