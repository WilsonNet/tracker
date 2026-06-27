export type TransportState = "stopped" | "playing" | "recording";

export type VimMode = "normal" | "insert" | "command";

export interface TrackData {
  id: number;
  name: string;
  armed: boolean;
  solo: boolean;
  muted: boolean;
  level: number;
  pan: number;
  input: string;
  eqLow: number;
  eqMid: number;
  eqHigh: number;
  reverb: number;
  echo: number;
}

export interface RhythmData {
  enabled: boolean;
  pattern: string;
  tempo: number;
  patternName: string;
}

export interface BounceState {
  canUndo: boolean;
  inProgress: boolean;
}

export const DRUM_PATTERNS = [
  "Rock",
  "Funk",
  "Hip Hop",
  "Heavy Metal",
  "Blues",
  "Jazz",
  "Pop",
  "Electronic",
  "R&B",
  "Country",
] as const;

export interface AudioDeviceInfo {
  id: string;
  name: string;
  input_channels: number;
  is_default: boolean;
}

export interface LevelUpdate {
  input_a_peak: number;
  input_a_rms: number;
  input_b_peak: number;
  input_b_rms: number;
  recording: boolean;
  armed_tracks: boolean[];
  metrics: {
    underruns: number;
    overruns: number;
    callback_interval_ms: number;
  };
}

export interface RecordingStatus {
  active: boolean;
  armed: boolean[];
  file_count: number;
  output_dir: string;
}

export function defaultTrack(id: number): TrackData {
  return {
    id,
    name: `Track ${id + 1}`,
    armed: false,
    solo: false,
    muted: false,
    level: 0.75,
    pan: 0.5,
    input: id === 0 ? "A" : id === 1 ? "B" : "Off",
    eqLow: 0.5,
    eqMid: 0.5,
    eqHigh: 0.5,
    reverb: 0,
    echo: 0,
  };
}
